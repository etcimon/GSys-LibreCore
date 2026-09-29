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

/// Queue 0 is `0x0120`. Later queues start at `0x01A0` so they do not cover
/// the descriptor latch at `0x0140` or the PMU at `0x0180`.
fn queue_slot(off: u16) -> Option<(usize, usize)> {
    let (origin, q_base) = if (mmio::REG0..mmio::DESC).contains(&off) {
        (mmio::REG0, 0usize)
    } else if off >= mmio::REG_QUEUE_TAIL {
        let n_tail = (NUM_QUEUES as u16).saturating_sub(1);
        let end = mmio::REG_QUEUE_TAIL.saturating_add(n_tail.saturating_mul(0x20));
        if off >= end {
            return None;
        }
        (mmio::REG_QUEUE_TAIL, 1usize)
    } else {
        return None;
    };
    let rel = off.wrapping_sub(origin);
    let q = q_base + (rel / 0x20) as usize;
    let slot = ((rel % 0x20) / 4) as usize;
    if q >= NUM_QUEUES {
        None
    } else {
        Some((q, slot))
    }
}

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
    /// Software completion history (CAP.queue_depth). Models g6lc_ai_cpl_fifo:
    /// oldest-first head; per-entry IRQ for head-driven irq after claim/pop.
    comp_history: VecDeque<(Completion, bool)>,
    traces: Vec<crate::format_trace::FormatTrace>,
    trace_desc: Option<Desc64>,
    /// Float products. Off unless this island is the software reference.
    fp_datapath: bool,
    /// Next completion beat fails after the GEMM result is stored.
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
    /// Optional command-queue extension v1 (`completion-fifo.md`). Depth 0 = absent.
    command_depth: u16,
    cmd_mode: bool,
    cmd_ptr: u64,
    cmd_ticket: u32,
    cmd_qid: u8,
    cmd_receipt: (u32, u32),
    cmd_counts: (u32, u32),
    commands: VecDeque<(u64, u32, u8)>,
    /// Last write was refused by the queued-mode protection lock (APB PSLVERR).
    write_error: bool,
    /// `CAP_ACCMODE` bit 0: accumulate mode executable.
    accumulate: bool,
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
            traces: Vec::new(),
            trace_desc: None,
            fp_datapath: false,
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
            command_depth: 0,
            cmd_mode: false,
            cmd_ptr: 0,
            cmd_ticket: 0,
            cmd_qid: 0,
            cmd_receipt: (0, mmio::CMD_DISABLED),
            cmd_counts: (0, 0),
            commands: VecDeque::new(),
            write_error: false,
            accumulate: false,
        }
    }

    /// Grant `flags.accmode == 01` (published at `CAP_ACCMODE`).
    pub fn set_accumulate(&mut self, on: bool) {
        self.accumulate = on;
    }

    /// Provision the optional command queue (CAP `0x90`). Zero removes it.
    pub fn set_command_depth(&mut self, depth: u16) {
        self.command_depth = depth;
    }

    fn cmd_quiescent(&self) -> bool {
        self.commands.is_empty() && self.comp_history.is_empty() && !self.busy
    }

    fn cmd_locked(&self, off: u16) -> bool {
        self.cmd_mode
            && (off == mmio::CTL
                || off == mmio::DOORBELL
                || off == mmio::REG_REUSE_EPOCH
                || off == mmio::REG_VA_TURBO_LEVEL
                || off == mmio::REG_VA_TURBO_RECIPE
                || off == mmio::REG_VA_TURBO_WINDOW
                || queue_slot(off).is_some())
    }

    fn cmd_submit(&mut self) {
        let ticket = self.cmd_ticket;
        let code = if !self.cmd_mode || !self.enable {
            mmio::CMD_DISABLED
        } else if self.commands.len() >= usize::from(self.command_depth) {
            mmio::CMD_FULL
        } else {
            self.commands.push_back((self.cmd_ptr, ticket, self.cmd_qid));
            mmio::CMD_ACCEPTED
        };
        self.cmd_receipt = (ticket, code);
        if code == mmio::CMD_ACCEPTED {
            self.cmd_counts.0 = self.cmd_counts.0.wrapping_add(1);
        } else {
            self.cmd_counts.1 = self.cmd_counts.1.wrapping_add(1);
        }
        self.cmd_dispatch();
    }

    /// Dispatch in order while the completion FIFO has room (RTL reserves a slot).
    fn cmd_dispatch(&mut self) {
        while self.comp_history.len() < self.history_cap() {
            let Some((ptr, ticket, qid)) = self.commands.pop_front() else { break };
            if usize::from(qid) >= usize::from(self.cap.queues.max(1)) {
                self.complete(ticket, ST_BAD_QID, false);
            } else if ptr == 0 || ptr & 7 != 0 || !self.region_ok(qid, ptr, DESC_BYTES as u64, true, false) {
                self.complete(ticket, ST_BAD_PTR, false);
            } else if let Ok(off) = self.off(ptr) {
                if off + DESC_BYTES > self.mem.len() {
                    self.complete(ticket, ST_ERR, false);
                    continue;
                }
                for i in 0..16 {
                    let b = &self.mem[off + i * 4..off + i * 4 + 4];
                    self.desc_words[i] = u32::from_le_bytes(b.try_into().unwrap());
                }
                self.execute_desc(qid, ticket);
            } else {
                self.complete(ticket, ST_BAD_PTR, false);
            }
        }
    }

    pub fn set_fp_datapath(&mut self, on: bool) {
        self.fp_datapath = on;
    }

    pub fn format_traces(&self) -> &[crate::format_trace::FormatTrace] {
        &self.traces
    }

    pub fn caps_from_cap(&self) -> Caps {
        let mut c = Caps::from_cap_regs(self.cap, self.noc_width);
        c.wr_cpl_en = self.wr_cpl_en;
        c.compute_ref = true;
        c.accumulate = self.accumulate;
        c
    }

    fn history_cap(&self) -> usize {
        self.cap.queue_depth.max(1) as usize
    }

    fn push_history(&mut self, c: Completion, irq: bool) {
        self.comp_history.push_back((c, irq));
        let cap = self.history_cap().max(4);
        while self.comp_history.len() > cap {
            self.comp_history.pop_front();
        }
    }

    /// Find a past completion by ticket (does not clear DONE sticky).
    pub fn history_lookup(&self, ticket: u32) -> Option<Completion> {
        self.comp_history
            .iter()
            .rev()
            .find(|(c, _)| c.ticket == ticket)
            .map(|(c, _)| *c)
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
            19 => mmio::CAP_LAYOUT_B_KMAJOR,
            37 => u32::from(self.accumulate) * mmio::CAP_ACCMODE_ACCUMULATE,
            36 if self.command_depth != 0 => {
                (u32::from(self.command_depth) << 16)
                    | (mmio::COMMAND_QUEUE_VERSION << 8)
                    | mmio::COMMAND_QUEUE_FLAGS
            }
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
        self.trace_desc = Some(Desc64 {
            version: d.version,
            op: d.op,
            flags: d.flags,
            m: d.m,
            n: d.n,
            k: d.k,
            ld_ab: d.ld_ab,
            ptr_a: d.ptr_a,
            ptr_b: d.ptr_b,
            ptr_c: d.ptr_c,
            ptr_scale: d.ptr_scale,
            ptr_done: d.ptr_done,
        });

        if !self.enable {
            self.complete(ticket, ST_DISABLED, false);
            return;
        }
        // Sim pin is Queues=1. The RTL keeps two queues: q0 at 0x0120 and q1 at
        // 0x01A0, because 0x0140 is the descriptor latch. Reject a qid the CAP
        // does not advertise.
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

        if crate::numfmt::check_desc_engine_acc(&d, self.cap.dtype_mask, self.fp_datapath, self.accumulate).is_err() {
            self.complete(ticket, ai_tensor_abi::ST_BAD_FMT, false);
            return;
        }
        let layout = match crate::numfmt::Layout::from_desc(&d) {
            Ok(l) => l,
            Err(_) => {
                self.complete(ticket, ST_BAD_PTR, false);
                return;
            }
        };
        let a_len = layout.a_bytes as u64;
        let b_len = layout.b_bytes as u64;
        let c_len = layout.c_bytes as u64;
        if !self.region_ok(qid, d.ptr_a, a_len, true, false)
            || !self.region_ok(qid, d.ptr_b, b_len, true, false)
            || !self.region_ok(qid, d.ptr_c, c_len, false, true)
        {
            self.complete(ticket, ST_BAD_PTR, false);
            return;
        }
        if d.ptr_done != 0
            && self.wr_cpl_en
            && (!self.region_ok(qid, d.ptr_done, 8, false, true)
                || crate::numfmt::memory_range(d.ptr_done, MEM_BASE, 8, self.mem.len()).is_err())
        {
            self.complete(ticket, ST_BAD_PTR, false);
            return;
        }

        let obs = match crate::reuse::execute(
            &mut self.reuse,
            self.reuse_epoch,
            &mut self.mem,
            MEM_BASE,
            &d,
            true,
        ) {
            Ok(obs) => obs,
            Err(_) => {
                self.complete(ticket, ST_BAD_PTR, false);
                return;
            }
        };
        self.last_read_a = obs.read_a;
        self.last_read_b = obs.read_b;

        // PMU estimate. A reuse hit contributes no beats for that operand.
        let bytes_r = (if obs.read_a { a_len } else { 0 }) + (if obs.read_b { b_len } else { 0 });
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

        self.complete(ticket, ST_OK, d.irq());
    }

    fn complete(&mut self, ticket: u32, status: u16, irq: bool) {
        let bus_err = self.completion_bus_err;
        self.completion_bus_err = false;
        let post = ai_tensor_abi::completion_post(ticket, status, bus_err);
        if self.wr_cpl_en {
            if let Some(d) = self.trace_desc.as_ref() {
                if d.ptr_done != 0 {
                    if let Ok(off) = self.off(d.ptr_done) {
                        if off + 8 <= self.mem.len() {
                            self.mem[off..off + 8].copy_from_slice(&post.word.to_le_bytes());
                        }
                    }
                }
            }
        }
        if let Some(d) = self.trace_desc.take() {
            self.traces
                .push(crate::format_trace::FormatTrace::from_desc(&d, status));
        }
        // FIFO push (oldest-first head); matches g6lc_ai_cpl_fifo.
        // A completion-beat failure does not rewrite the stored GEMM word.
        let c = Completion {
            ticket,
            status: post.fifo_status,
        };
        self.push_history(c, irq);
        self.last_comp = Some(c);
        self.last_status = post.fifo_status;
        self.busy = false;
        self.pmu_va_level = ai_tensor_abi::mmio::va_turbo_level_word(self.va_level_req);
        self.pmu_va_recipe = ai_tensor_abi::mmio::va_turbo_recipe_word(self.va_recipe_req);
        self.pmu_window = self.window_valid;
        self.refresh_done_head();
    }

    fn cmd_read(&self, off: u16) -> Option<u32> {
        if self.command_depth == 0 {
            return None;
        }
        Some(match off {
            mmio::CMD_MODE => u32::from(self.cmd_mode),
            mmio::CMD_PTR_LO => self.cmd_ptr as u32,
            mmio::CMD_PTR_HI => (self.cmd_ptr >> 32) as u32,
            mmio::CMD_TICKET => self.cmd_ticket,
            mmio::CMD_QID => u32::from(self.cmd_qid),
            mmio::CMD_CREDITS => u32::from(self.command_depth) - self.commands.len() as u32,
            mmio::CMD_RECEIPT_TICKET => self.cmd_receipt.0,
            mmio::CMD_RECEIPT_CODE => self.cmd_receipt.1,
            mmio::CMD_ACCEPTED_COUNT => self.cmd_counts.0,
            mmio::CMD_REJECTED_COUNT => self.cmd_counts.1,
            _ => return None,
        })
    }

    /// Returns true when the write belonged to the command window.
    fn cmd_write(&mut self, off: u16, val: u32) -> bool {
        if self.command_depth == 0 {
            return false;
        }
        match off {
            mmio::CMD_MODE => {
                let want = val & 1 != 0;
                if want != self.cmd_mode && (!self.cmd_quiescent() || (want && !self.enable)) {
                    self.write_error = true;
                } else {
                    self.cmd_mode = want;
                }
            }
            mmio::CMD_PTR_LO => self.cmd_ptr = (self.cmd_ptr & !0xffff_ffff) | u64::from(val),
            mmio::CMD_PTR_HI => self.cmd_ptr = (self.cmd_ptr & 0xffff_ffff) | (u64::from(val) << 32),
            mmio::CMD_TICKET => self.cmd_ticket = val,
            mmio::CMD_QID => self.cmd_qid = (val & 0xff) as u8,
            mmio::CMD_SUBMIT => {
                if val & 1 != 0 {
                    self.cmd_submit();
                }
            }
            _ => return false,
        }
        true
    }

    /// After push/pop: expose FIFO head on DONE/TICKET/DSTATUS and IRQ.
    /// RTL: irq_o = !empty && head.irq
    fn refresh_done_head(&mut self) {
        if let Some((front, irq)) = self.comp_history.front().copied() {
            self.done_sticky = true;
            self.done_ticket = front.ticket;
            self.done_status = front.status;
            self.irq_sticky = irq;
        } else {
            self.done_sticky = false;
            self.irq_sticky = false;
        }
    }

    fn claim_pop(&mut self) {
        let _ = self.comp_history.pop_front();
        self.refresh_done_head();
        self.cmd_dispatch();
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
        if let Some(v) = self.cmd_read(off) {
            return v;
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
            ai_tensor_abi::mmio::REG_REUSE_EPOCH => self.reuse_epoch,
            ai_tensor_abi::mmio::REG_VA_TURBO_LEVEL => ai_tensor_abi::mmio::va_turbo_level_word(self.va_level_req),
            ai_tensor_abi::mmio::PMU_VA_TURBO_LEVEL => self.pmu_va_level,
            ai_tensor_abi::mmio::REG_VA_TURBO_RECIPE => {
                ai_tensor_abi::mmio::va_turbo_recipe_word(self.va_recipe_req)
            }
            ai_tensor_abi::mmio::PMU_VA_TURBO_RECIPE => self.pmu_va_recipe,
            ai_tensor_abi::mmio::REG_VA_TURBO_WINDOW => u32::from(self.window_valid),
            ai_tensor_abi::mmio::PMU_VA_TURBO_WINDOW => u32::from(self.pmu_window),
            0x0180 => self.pmu.r_beats,
            0x0184 => self.pmu.w_beats,
            0x0188 => self.pmu.cycles,
            0x018C => self.pmu.gbps_x1000,
            o if (0x0140..0x0180).contains(&o) => self.desc_words[((o - 0x0140) / 4) as usize],
            o => {
                if let Some((q, slot)) = queue_slot(o) {
                    match slot {
                        0 => self.base[q] as u32,
                        1 => (self.base[q] >> 32) as u32,
                        2 => self.limit[q] as u32,
                        3 => (self.limit[q] >> 32) as u32,
                        4 => u32::from(self.perm[q]),
                        _ => 0,
                    }
                } else {
                    0
                }
            }
        }
    }

    fn write32(&mut self, off: u16, val: u32) {
        self.write_error = false;
        if self.cmd_locked(off) {
            self.write_error = true;
            return;
        }
        if self.cmd_write(off, val) {
            return;
        }
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
            ai_tensor_abi::mmio::REG_REUSE_EPOCH => {
                self.reuse_epoch = val;
                self.window_valid = false;
            }
            ai_tensor_abi::mmio::REG_VA_TURBO_LEVEL => {
                self.va_level_req = ai_tensor_abi::mmio::va_turbo_level_word(val);
                self.window_valid = false;
            }
            ai_tensor_abi::mmio::REG_VA_TURBO_RECIPE => {
                self.va_recipe_req = ai_tensor_abi::mmio::va_turbo_recipe_word(val);
                self.window_valid = false;
            }
            ai_tensor_abi::mmio::REG_VA_TURBO_WINDOW => {
                self.window_valid = val & 1 != 0;
            }
            o if (0x0140..0x0180).contains(&o) => {
                self.desc_words[((o - 0x0140) / 4) as usize] = val;
            }
            o => {
                if let Some((q, slot)) = queue_slot(o) {
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
            }
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

    /// Soft island with an explicit CAP record. The live constructor stays
    /// [`Self::new`], which is the 512-MAC panel.
    pub fn with_cap(cap: CapRegs) -> Self {
        let island = SoftIsland::with_cap(cap, 64);
        let cached_caps = island.caps_from_cap();
        Self {
            island,
            cached_caps,
        }
    }

    pub fn software_reference_v2() -> Self {
        let mut cap = CapRegs::island_p3_sim_default();
        cap.dtype_mask = crate::numfmt::SOFTWARE_DTYPE_MASK;
        let mut island = SoftIsland::with_cap(cap, 64);
        island.set_fp_datapath(true);
        island.set_accumulate(true);
        let mut cached_caps = island.caps_from_cap();
        cached_caps.fp_datapath = true;
        cached_caps.accumulate = true;
        Self { island, cached_caps }
    }

    /// Soft island provisioned with the optional command queue (CAP `0x90`).
    pub fn with_command_queue(depth: u16) -> Self {
        let mut dev = Self::new();
        dev.island.set_command_depth(depth);
        dev
    }

    /// Advertised command-queue depth, or 0 when the extension is absent.
    pub fn command_queue_depth(&mut self) -> u16 {
        let word = self.island.read32(mmio::CAP_COMMAND_QUEUE);
        if word == 0 || (word >> 8) & 0xff != mmio::COMMAND_QUEUE_VERSION || word & 7 != 7 {
            return 0;
        }
        (word >> 16) as u16
    }

    /// Enter or leave queued mode. Refused (Err) unless the island is quiescent
    /// and, when entering, enabled.
    pub fn set_queued_mode(&mut self, on: bool) -> Result<(), RtError> {
        if self.command_queue_depth() == 0 {
            return Err(RtError::Msg("command queue not advertised".into()));
        }
        self.island.write32(mmio::CMD_MODE, u32::from(on));
        if self.island.write_error || (self.island.read32(mmio::CMD_MODE) & 1 != 0) != on {
            return Err(RtError::Msg("queued mode transition refused".into()));
        }
        Ok(())
    }

    /// One MMIO submit attempt of a descriptor already resident at `desc_ptr`.
    /// `Ok(true)` = accepted (the caller's buffers stay leased until the
    /// completion is claimed); `Ok(false)` = definite full refusal, retry
    /// permitted; `Err` = disabled/unsupported, nothing was queued.
    pub fn queued_submit(&mut self, qid: u8, ticket: u32, desc_ptr: u64) -> Result<bool, RtError> {
        if self.command_queue_depth() == 0 {
            return Err(RtError::Msg("command queue not advertised".into()));
        }
        if desc_ptr == 0 || desc_ptr & 7 != 0 {
            return Err(RtError::Msg("queued descriptor pointer must be nonzero and 8-byte aligned".into()));
        }
        self.island.write32(mmio::CMD_PTR_LO, desc_ptr as u32);
        self.island.write32(mmio::CMD_PTR_HI, (desc_ptr >> 32) as u32);
        self.island.write32(mmio::CMD_TICKET, ticket);
        self.island.write32(mmio::CMD_QID, u32::from(qid));
        self.island.write32(mmio::CMD_SUBMIT, 1);
        if self.island.read32(mmio::CMD_RECEIPT_TICKET) != ticket {
            return Err(RtError::Msg("ambiguous command receipt".into()));
        }
        match self.island.read32(mmio::CMD_RECEIPT_CODE) {
            mmio::CMD_ACCEPTED => Ok(true),
            mmio::CMD_FULL => Ok(false),
            mmio::CMD_DISABLED => Err(RtError::Msg("command queue disabled".into())),
            _ => Err(RtError::Msg("unknown command receipt".into())),
        }
    }

    /// Advisory free command slots.
    pub fn queued_credits(&mut self) -> u32 {
        self.island.read32(mmio::CMD_CREDITS)
    }

    /// The last register write was refused by the queued-mode lock.
    pub fn last_write_refused(&self) -> bool {
        self.island.write_error
    }

    /// Re-probe CAP through MMIO (as a real backend would after map).
    /// The next completion beat returns SLVERR after the GEMM word is stored.
    pub fn fail_next_completion_bus(&mut self) {
        self.island.completion_bus_err = true;
    }

    pub fn reuse_epoch(&self) -> u32 {
        self.island.reuse_epoch
    }

    pub fn va_turbo_level_word(&self) -> u32 {
        ai_tensor_abi::mmio::va_turbo_level_word(self.island.va_level_req)
    }

    pub fn pmu_va_turbo_level(&self) -> u32 {
        self.island.pmu_va_level
    }

    pub fn va_turbo_recipe_word(&self) -> u32 {
        ai_tensor_abi::mmio::va_turbo_recipe_word(self.island.va_recipe_req)
    }

    pub fn pmu_va_turbo_recipe(&self) -> u32 {
        self.island.pmu_va_recipe
    }

    pub fn va_turbo_window(&self) -> bool {
        self.island.window_valid
    }

    pub fn pmu_va_turbo_window(&self) -> bool {
        self.island.pmu_window
    }

    /// Whether exact reuse is enabled. A plan with no skip leaves it off.
    pub fn reuse_enabled(&self) -> bool {
        self.island.reuse.enabled()
    }

    pub fn reuse_read_a(&self) -> bool {
        self.island.last_read_a
    }

    pub fn reuse_read_b(&self) -> bool {
        self.island.last_read_b
    }

    pub fn probe_caps(&mut self) -> Caps {
        let cap = probe_cap_regs(&mut self.island);
        let noc = self.island.noc_width;
        let mut c = Caps::from_cap_regs(cap, noc);
        // wr_cpl from CTL after enable is separate; default true until CTL written
        c.wr_cpl_en = self.island.wr_cpl_en;
        c.compute_ref = true;
        c.fp_datapath = self.island.fp_datapath;
        c.accumulate = self.island.accumulate;
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
        // q0 is 0x0120. q>=1 starts at 0x01A0 so it does not cover the latch.
        let nq = self.cached_caps.queues.max(1);
        if u32::from(qid) >= nq {
            return Err(RtError::BadPtr("qid exceeds CAP.queues / MMIO map"));
        }
        let base_off = mmio::queue_region(u16::from(qid));
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
        if ticket > mmio::DOORBELL_TICKET_MAX {
            return Err(RtError::Msg("ticket exceeds the 23-bit doorbell field".into()));
        }
        // Latch 64 B descriptor at 0x140
        let b = desc.pack();
        for i in 0..16 {
            let w = u32::from_le_bytes(b[i * 4..i * 4 + 4].try_into().unwrap());
            self.island.write32(mmio::DESC + (i as u16) * 4, w);
        }
        // Doorbell: ticket[30:8] | qid[7:0], bit31=0 latch path
        let db = ticket << 8 | u32::from(qid);
        self.island.write32(mmio::DOORBELL, db);
        Ok(())
    }

    fn submit_fetch(&mut self, qid: u8, ticket: u32, desc: &Desc64) -> Result<(), RtError> {
        if ticket > mmio::DOORBELL_TICKET_MAX {
            return Err(RtError::Msg("ticket exceeds the 23-bit doorbell field".into()));
        }
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
        self.poll_completion(ticket, true)
    }

    fn poll_completion(&mut self, ticket: u32, claim: bool) -> Result<Option<Completion>, RtError> {
        let done = self.island.read32(mmio::DONE) & 1 != 0;
        if done {
            let t = self.island.read32(mmio::TICKET);
            let st = (self.island.read32(mmio::DSTATUS) & 0xffff) as u16;
            if t == ticket {
                // SW clears done sticky after claim (PLIC-like discipline)
                if claim {
                    self.island.write32(mmio::DONE, 1);
                }
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

    fn set_reuse_epoch(&mut self, epoch: u32) -> Result<(), RtError> {
        self.island
            .write32(ai_tensor_abi::mmio::REG_REUSE_EPOCH, epoch);
        Ok(())
    }

    fn set_va_turbo_level(&mut self, level: u32) -> Result<(), RtError> {
        self.island
            .write32(ai_tensor_abi::mmio::REG_VA_TURBO_LEVEL, level);
        Ok(())
    }

    fn set_va_turbo_recipe(&mut self, id: u32) -> Result<(), RtError> {
        self.island
            .write32(ai_tensor_abi::mmio::REG_VA_TURBO_RECIPE, id);
        Ok(())
    }

    fn set_va_turbo_window(&mut self, valid: bool) -> Result<(), RtError> {
        self.island
            .write32(ai_tensor_abi::mmio::REG_VA_TURBO_WINDOW, u32::from(valid));
        Ok(())
    }

    fn set_reuse_en(&mut self, on: bool) -> Result<(), RtError> {
        self.island.reuse.set_enabled(on);
        Ok(())
    }

    fn reuse_enabled(&self) -> bool {
        MmioDevice::reuse_enabled(self)
    }

    fn reuse_read_a(&self) -> bool {
        MmioDevice::reuse_read_a(self)
    }

    fn reuse_read_b(&self) -> bool {
        MmioDevice::reuse_read_b(self)
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
    let acc = c.acc_tile.m.trailing_zeros()
        | (c.acc_tile.n.trailing_zeros() << 4)
        | (c.acc_tile.k.trailing_zeros() << 8);
    bus.write32(0x00, u32::from(c.version));
    bus.write32(0x04, c.clusters);
    bus.write32(0x08, c.macs_per_cycle);
    bus.write32(0x0c, c.clock_khz);
    bus.write32(0x10, c.sram_bytes);
    bus.write32(0x14, acc);
    bus.write32(0x18, u32::from(c.dram_nameplate_gbps));
    bus.write32(0x1c, u32::from(c.queues) | (u32::from(c.queue_depth) << 16));
    bus.write32(0x28, u32::from(c.dtype_mask));
    bus.write32(mmio::CAP_LAYOUT, mmio::CAP_LAYOUT_B_KMAJOR);
}


#[cfg(test)]
mod tests {
    use super::*;
    use ai_tensor_abi::AccTile;
    use crate::run_gemm_s8;

    #[test]
    fn q1_region_does_not_alias_desc_latch() {
        let mut isl = SoftIsland::new();
        isl.write32(mmio::DESC, 0xA5A5_A5A5);
        isl.write32(mmio::queue_region(1) + 0x10, 3);
        assert_eq!(isl.read32(mmio::DESC), 0xA5A5_A5A5);
        assert_eq!(isl.read32(mmio::queue_region(1) + 0x10), 3);
        // The old stride 0x0120+0x20 is a descriptor word, not queue 1.
        isl.write32(0x0150, 0x1111_1111);
        assert_eq!(isl.read32(0x0150), 0x1111_1111);
        assert_eq!(isl.read32(mmio::queue_region(1) + 0x10), 3);
        assert_eq!(mmio::queue_region(0), 0x0120);
        assert_eq!(mmio::queue_region(1), 0x01A0);
    }

    #[test]
    fn cap_probe_acc_tile_256() {
        let mut dev = MmioDevice::new();
        let c = dev.probe_caps();
        assert_eq!(c.acc_tile, AccTile::ISLAND_P3_DEFAULT);
        assert_eq!(c.macs_per_cycle, 512);
        assert_eq!(c.acc_tile.m, 1024);
        assert_eq!(c.acc_tile.n, 512);
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
    fn command_queue_absent_by_default() {
        let mut dev = MmioDevice::new();
        assert_eq!(dev.command_queue_depth(), 0);
        assert!(dev.set_queued_mode(true).is_err());
        assert!(dev.queued_submit(0, 1, 0x1000).is_err());
        assert_eq!(dev.island.read32(mmio::CMD_MODE), 0);
    }

    #[test]
    fn command_queue_receipts_lock_and_identity() {
        let mut dev = MmioDevice::with_command_queue(2);
        assert_eq!(dev.command_queue_depth(), 2);
        assert!(dev.set_queued_mode(true).is_err(), "queued mode needs CTL.enable");
        dev.enable(true);
        dev.set_wr_cpl_en(false);
        dev.program_region(0, Region { base: 0x1000, limit: 0x1000 + (1 << 20), read: true, write: true }).unwrap();
        let pa = dev.alloc(4).unwrap();
        let pb = dev.alloc(4).unwrap();
        let pc = dev.alloc(16).unwrap();
        dev.write_mem(pa, &[1, 2, 3, 4]).unwrap();
        dev.write_mem(pb, &[5, 7, 6, 8]).unwrap();
        let mut descs = Vec::new();
        for _ in 0..2 {
            let ptr = dev.alloc(64).unwrap();
            dev.write_mem(ptr, &Desc64::gemm(2, 2, 2).with_ptrs(pa, pb, pc, 0).pack()).unwrap();
            descs.push(ptr);
        }
        dev.set_queued_mode(true).unwrap();
        // Protected writes are refused without effect while queued.
        dev.island.write32(mmio::CTL, 0);
        assert!(dev.last_write_refused());
        assert_eq!(dev.island.read32(mmio::CTL) & 1, 1);
        dev.island.write32(mmio::queue_region(0) + 0x10, 0);
        assert!(dev.last_write_refused());
        assert!(dev.queued_submit(0, 0xF000_0001, descs[0]).unwrap());
        assert!(dev.queued_submit(0, 0xF000_0002, descs[1]).unwrap());
        let c1 = dev.poll_completion(0xF000_0001, true).unwrap().unwrap();
        let c2 = dev.poll_completion(0xF000_0002, true).unwrap().unwrap();
        assert!(c1.is_ok() && c2.is_ok());
        let mut out = [0u8; 16];
        dev.read_mem(pc, &mut out).unwrap();
        let c: Vec<i32> = out.chunks(4).map(|w| i32::from_le_bytes(w.try_into().unwrap())).collect();
        assert_eq!(c, vec![19, 22, 43, 50]);
        // Invalid qid and zero pointer complete with their own tickets, not silently.
        assert!(dev.queued_submit(9, 0xF000_0003, descs[0]).unwrap());
        assert_eq!(dev.poll_completion(0xF000_0003, true).unwrap().unwrap().status, ST_BAD_QID);
        assert!(dev.queued_submit(0, 0xF000_0004, 0).is_err());
        assert_eq!(dev.island.read32(mmio::CMD_ACCEPTED_COUNT), 3);
        assert_eq!(dev.island.read32(mmio::CMD_REJECTED_COUNT), 0);
        assert_eq!(dev.queued_credits(), 2);
        dev.set_queued_mode(false).unwrap();
        // Disabled mode: definite refusal, nothing queued.
        assert!(dev.queued_submit(0, 0xF000_0005, descs[0]).is_err());
        assert_eq!(dev.island.read32(mmio::CMD_REJECTED_COUNT), 1);
    }

    #[test]
    fn command_queue_full_refusal_is_definite() {
        let mut dev = MmioDevice::with_command_queue(1);
        dev.enable(true);
        // Make the completion FIFO artificially full so dispatch cannot drain.
        for t in 0..64u32 {
            dev.island.complete(t, ST_OK, false);
        }
        dev.set_queued_mode(true).unwrap_err(); // not quiescent with completions pending
        while dev.island.read32(mmio::DONE) & 1 != 0 {
            dev.island.write32(mmio::DONE, 1);
        }
        dev.set_queued_mode(true).unwrap();
        for t in 0..64u32 {
            dev.island.complete(t, ST_OK, false);
        }
        assert!(dev.queued_submit(0, 100, 0x1000).unwrap());
        assert!(!dev.queued_submit(0, 101, 0x1000).unwrap());
        assert_eq!(dev.queued_credits(), 0);
        assert!(dev.set_queued_mode(false).is_err(), "pending command must block mode exit");
        // One claim frees one completion slot: the held command dispatches (bad
        // ptr: no region programmed) and keeps its own ticket.
        dev.island.write32(mmio::DONE, 1);
        assert_eq!(dev.queued_credits(), 1);
        while dev.island.read32(mmio::DONE) & 1 != 0 && dev.island.read32(mmio::TICKET) != 100 {
            dev.island.write32(mmio::DONE, 1);
        }
        assert_eq!(dev.island.read32(mmio::TICKET), 100);
        assert_eq!(dev.island.read32(mmio::DSTATUS) as u16, ST_BAD_PTR);
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
        dev.write_mem(pbb, &[5, 7, 6, 8]).unwrap();
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
        assert_eq!(w.read32(mmio::CAP_LAYOUT), mmio::CAP_LAYOUT_B_KMAJOR);
        assert_eq!(SoftIsland::new().read32(mmio::CAP_LAYOUT), mmio::CAP_LAYOUT_B_KMAJOR);
        assert_eq!(cap.macs_per_cycle, 512);
        assert_eq!(cap.acc_tile.m, 1024);
        assert_eq!(cap.acc_tile.n, 512);
    }

    fn queued_pair() -> (MmioDevice, u64) {
        let mut dev = MmioDevice::new();
        dev.enable(true);
        dev.program_region(0, Region {
            base: 0x1000, limit: 0x1000 + (1 << 20), read: true, write: true,
        }).unwrap();
        let pa = dev.alloc(1).unwrap();
        let pb = dev.alloc(1).unwrap();
        let pc = dev.alloc(4).unwrap();
        let pd = dev.alloc(8).unwrap();
        dev.write_mem(pa, &[2]).unwrap();
        dev.write_mem(pb, &[3]).unwrap();
        let desc = Desc64::gemm(1, 1, 1).with_ptrs(pa, pb, pc, pd).with_irq(true);
        dev.submit(0, 41, &desc).unwrap();
        dev.submit(0, 42, &desc).unwrap();
        assert_eq!(dev.island.read32(mmio::TICKET), 41);
        (dev, pd)
    }

    #[test]
    fn dma_claim_consumes_only_the_requested_head() {
        let (mut dev, pd) = queued_pair();
        let c = crate::wait_with_policy(&mut dev, 41, crate::WaitPolicy::DmaThenClaim {
            ptr_done: pd, claim: true,
        }).unwrap();
        assert_eq!(c.ticket, 41);
        assert_eq!(dev.island.read32(mmio::DONE), 1);
        assert_eq!(dev.island.read32(mmio::TICKET), 42);
        assert!(dev.irq_pending());
    }

    #[test]
    fn dma_observation_does_not_claim() {
        let (mut dev, pd) = queued_pair();
        let c = crate::wait_with_policy(&mut dev, 41, crate::WaitPolicy::DmaThenClaim {
            ptr_done: pd, claim: false,
        }).unwrap();
        assert_eq!(c.ticket, 41);
        assert_eq!(dev.island.read32(mmio::TICKET), 41);
        assert!(dev.irq_pending());
    }

    #[test]
    fn irq_claim_consumes_only_the_requested_head() {
        let (mut dev, _) = queued_pair();
        assert_eq!(crate::wait_irq_then_claim(&mut dev, 41, 10).unwrap().ticket, 41);
        assert_eq!(dev.island.read32(mmio::DONE), 1);
        assert_eq!(dev.island.read32(mmio::TICKET), 42);
        assert!(dev.irq_pending());
    }

    #[test]
    fn mmio_rejects_unrepresentable_tickets_before_submission() {
        for fetch in [false, true] {
            let mut dev = MmioDevice::new();
            let desc = Desc64::gemm(1, 1, 1);
            for ticket in [0x0080_0000, u32::MAX] {
                let before = dev.island.read32(mmio::DESC);
                let result = if fetch {
                    dev.submit_fetch(0, ticket, &desc)
                } else {
                    dev.submit(0, ticket, &desc)
                };
                assert!(result.is_err(), "ticket {ticket:#x}, fetch={fetch}");
                assert_eq!(dev.island.read32(mmio::DESC), before);
                assert_eq!(dev.island.read32(mmio::DONE), 0);
            }
        }
    }

    #[test]
    fn completion_bus_error_leaves_the_gemm_word() {
        let mut dev = MmioDevice::new();
        dev.probe_caps();
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
        let d = Desc64::gemm(1, 1, 1).with_ptrs(pa, pb, pc, pd);
        dev.fail_next_completion_bus();
        dev.submit(0, 42, &d).unwrap();
        let mut raw = [0u8; 8];
        dev.read_mem(pd, &mut raw).unwrap();
        let word = Completion::from_u64(u64::from_le_bytes(raw));
        assert_eq!(word.ticket, 42);
        assert_eq!(word.status, ST_OK);
        assert_eq!(dev.poll(42).unwrap().unwrap().status, ST_ERR);
    }

    #[test]
    fn a_va_turbo_level_is_stored_and_the_dot_stays_exact() {
        let mut dev = MmioDevice::new();
        dev.set_va_turbo_level(0xFFFF_FFFF).unwrap();
        assert_eq!(dev.va_turbo_level_word(), 0xF);
        assert_eq!(dev.pmu_va_turbo_level(), 0);
        dev.set_va_turbo_level(0x109).unwrap();
        let (c, comp) = run_gemm_s8(&mut dev, 2, 2, 2, &[1, 2, 3, 4], &[5, 6, 7, 8], 1).unwrap();
        assert!(comp.is_ok());
        assert_eq!(c, vec![19, 22, 43, 50]);
        assert_eq!(dev.va_turbo_level_word(), 9);
        assert_eq!(dev.pmu_va_turbo_level(), 9);
        assert_eq!(ai_tensor_abi::mmio::va_turbo_level_applied(dev.pmu_va_turbo_level()), 0);
        dev.set_va_turbo_recipe(0x0110).unwrap();
        assert_eq!(dev.va_turbo_recipe_word(), 0x10);
        let (c2, comp2) = run_gemm_s8(&mut dev, 2, 2, 2, &[1, 2, 3, 4], &[5, 6, 7, 8], 2).unwrap();
        assert!(comp2.is_ok());
        assert_eq!(c2, vec![19, 22, 43, 50]);
        assert_eq!(dev.pmu_va_turbo_recipe(), 0x10);
        assert_eq!(ai_tensor_abi::mmio::va_turbo_recipe_applied(dev.pmu_va_turbo_recipe()), 0);
    }

    #[test]
    fn enabled_reuse_keeps_the_resident_b_byte() {
        use ai_tensor_abi::FLAG_REUSE_B;
        let mut dev = MmioDevice::new();
        dev.probe_caps();
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
        dev.set_reuse_en(true).unwrap();
        let pa = dev.alloc(1).unwrap();
        let pb = dev.alloc(1).unwrap();
        let pc = dev.alloc(4).unwrap();
        dev.write_mem(pa, &[1]).unwrap();
        dev.write_mem(pb, &[3]).unwrap();
        let mut d = Desc64::gemm(1, 1, 1).with_ptrs(pa, pb, pc, 0);
        dev.submit(0, 1, &d).unwrap();
        dev.write_mem(pb, &[8]).unwrap();
        d.flags = FLAG_REUSE_B;
        dev.submit(0, 2, &d).unwrap();
        let mut raw = [0u8; 4];
        dev.read_mem(pc, &mut raw).unwrap();
        assert_eq!(i32::from_le_bytes(raw), 3);
        assert!(!dev.reuse_read_b());
        dev.island
            .write32(ai_tensor_abi::mmio::REG_VA_TURBO_WINDOW, 1);
        assert_eq!(dev.island.read32(ai_tensor_abi::mmio::REG_VA_TURBO_WINDOW), 1);
        dev.island
            .write32(ai_tensor_abi::mmio::REG_REUSE_EPOCH, 1);
        assert_eq!(dev.island.read32(ai_tensor_abi::mmio::REG_REUSE_EPOCH), 1);
        assert_eq!(dev.reuse_epoch(), 1);
        assert_eq!(dev.island.read32(ai_tensor_abi::mmio::REG_VA_TURBO_WINDOW), 0);
        dev.submit(0, 3, &d).unwrap();
        dev.read_mem(pc, &mut raw).unwrap();
        assert_eq!(i32::from_le_bytes(raw), 8);
        assert!(dev.reuse_read_b());
        dev.island
            .write32(ai_tensor_abi::mmio::REG_VA_TURBO_WINDOW, 1);
        dev.island
            .write32(ai_tensor_abi::mmio::REG_REUSE_EPOCH, 1);
        assert_eq!(dev.island.read32(ai_tensor_abi::mmio::REG_REUSE_EPOCH), 1);
        assert_eq!(dev.island.read32(ai_tensor_abi::mmio::REG_VA_TURBO_WINDOW), 0);
        dev.submit(0, 4, &d).unwrap();
        dev.read_mem(pc, &mut raw).unwrap();
        assert_eq!(i32::from_le_bytes(raw), 8);
        assert!(!dev.reuse_read_b());
        dev.island
            .write32(ai_tensor_abi::mmio::REG_REUSE_EPOCH, 0xFFFF_FFFF);
        assert_eq!(
            dev.island.read32(ai_tensor_abi::mmio::REG_REUSE_EPOCH),
            0xFFFF_FFFF
        );
    }
}
