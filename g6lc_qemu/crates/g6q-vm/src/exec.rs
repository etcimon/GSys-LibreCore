// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Single-hart interpretive execution engine.
//!
//! Q3 starts with the interpreter tier: fetch, decode, execute, record. The record is
//! produced as a `g6q_diag::CommitRecord` so that the same engine can serve B3 and D1
//! from one path.

use std::fmt::Write;

use g6q_diag::CommitRecord;

use crate::insn::{decode_with_ai, Insn};
use crate::mem::{MemError, PhysMem};
use crate::regs::Fregs;
use crate::regs::Regs;
use crate::Clock;

/// Why execution stopped.
#[derive(Debug, Clone, PartialEq, Eq)]
#[allow(missing_docs)]
pub enum Halt {
    /// Reached the requested instruction limit.
    StepLimit,
    /// A replay diverged from the reference at the given record index.
    ReplayDivergence(usize, Vec<g6q_diag::FieldDiff>),
}

/// Result of a floating-point operation, including the accrued `fflags` mask.
#[derive(Debug, Clone, Copy)]
struct FpResult<T: Copy> {
    value: T,
    flags: u64,
}

use crate::csr::Csr;
use crate::mmu::{self, Mmu};

/// The state of one hart and its progress.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Hart {
    /// Architectural integer register file.
    pub regs: Regs,
    /// Architectural floating-point register file.
    pub fregs: Fregs,
    /// Deterministic clock.
    pub clock: Clock,
    /// Retired-instruction count.
    pub instret: u64,
    /// Monotonic record counter, increments for every committed or trapped instruction.
    pub record_order: u64,
    /// Records produced so far.
    pub records: Vec<CommitRecord>,
    /// Address reserved by the most recent `lr` on this hart.
    pub reservation: Option<u64>,
    /// Faulting address (or faulting instruction word) for the next trap.
    pub fault_addr: u64,
    /// Control and status registers.
    pub csr: Csr,
    /// Length of the instruction currently being executed (2 or 4 bytes).
    pub inst_len: u8,
    /// AI instruction set (match/mask values), when the model provides one.
    pub ai_instr_set: Option<g6q_core::model::AiInstrSet>,
    /// AI island model (config, descriptor layout, instruction set).
    pub ai_model: Option<g6q_core::model::AiIslandModel>,
    /// Model-derived MMU geometry; bare by default.
    pub mmu: Mmu,
}

impl Hart {
    /// Create a hart with the given initial PC and hart ID.
    pub fn new(pc: u64) -> Self {
        Self::with_hartid(pc, 0)
    }

    /// Create a hart with an explicit hart ID.
    pub fn with_hartid(pc: u64, hartid: u64) -> Self {
        Self {
            regs: Regs::new(pc),
            fregs: Fregs::new(),
            csr: Csr::new(hartid),
            inst_len: 4,
            ai_instr_set: None,
            ai_model: None,
            mmu: Mmu::default(),
            ..Self::default()
        }
    }

    /// Create a hart with the MMU geometry derived from a model ISA.
    pub fn with_isa(pc: u64, isa: &g6q_core::model::Isa) -> Self {
        let mut h = Self::new(pc);
        h.mmu = Mmu::from_isa(isa);
        h
    }

    /// Fetch, decode and execute one instruction.
    ///
    /// Returns the halt reason when something stops the hart. The hart advances by one
    /// instruction on success and appends a [`CommitRecord`].
    pub fn step(&mut self, mem: &mut PhysMem, xlen: u8) -> Option<Halt> {
        let pc = self.regs.pc;
        let pc_paddr = match self.translate(mem, pc, 12) {
            Ok(p) => p,
            Err(ExecError::Trap(c)) => {
                self.fault_addr = pc;
                self.take_trap(c);
                return None;
            }
        };

        // Fetch 2 bytes and determine instruction length.
        let (w, inst_len) = match mem.read_le::<2>(pc_paddr) {
            Ok(v) => {
                let h = v as u16;
                if h & 0b11 != 0b11 {
                    // 16-bit compressed
                    (h as u32, 2)
                } else if (h >> 2) & 0b111 != 0b111 {
                    // 32-bit standard; fetch the upper halfword.
                    let paddr2 = match self.translate(mem, pc.wrapping_add(2), 12) {
                        Ok(p) => p,
                        Err(ExecError::Trap(c)) => {
                            self.fault_addr = pc;
                            self.take_trap(c);
                            return None;
                        }
                    };
                    match mem.read_le::<2>(paddr2) {
                        Ok(v2) => (((v2 as u32) << 16) | (h as u32), 4),
                        Err(MemError::Misaligned) => {
                            self.fault_addr = self.regs.pc;
                            self.take_trap(0);
                            return None;
                        }
                        Err(MemError::OutOfBounds) | Err(MemError::Invalid) => {
                            self.fault_addr = self.regs.pc;
                            self.take_trap(1);
                            return None;
                        }
                    }
                } else {
                    // 48/64-bit and reserved encodings are not supported.
                    self.fault_addr = self.regs.pc;
                    self.take_trap(2);
                    return None;
                }
            }
            Err(MemError::Misaligned) => {
                self.fault_addr = self.regs.pc;
                self.take_trap(0);
                return None;
            }
            Err(MemError::OutOfBounds) | Err(MemError::Invalid) => {
                self.fault_addr = self.regs.pc;
                self.take_trap(1);
                return None;
            }
        };
        self.inst_len = inst_len;

        // Deliver M-mode software interrupt if globally and specifically enabled.
        if self.csr.mode() == 3
            && ((self.csr.mstatus >> 3) & 1) != 0
            && ((self.csr.mie >> 3) & 1) != 0
            && ((self.csr.mip >> 3) & 1) != 0
        {
            self.fault_addr = 0;
            self.take_trap(0x8000_0000_0000_0003);
            return None;
        }
        // Deliver M-mode timer interrupt if globally and specifically enabled.
        if self.csr.mode() == 3
            && ((self.csr.mstatus >> 3) & 1) != 0
            && ((self.csr.mie >> 7) & 1) != 0
            && ((self.csr.mip >> 7) & 1) != 0
        {
            self.fault_addr = 0;
            self.take_trap(0x8000_0000_0000_0007);
            return None;
        }
        // Deliver S-mode software interrupt if delegated and enabled.
        if self.csr.mode() <= 1
            && ((self.csr.mstatus >> 1) & 1) != 0
            && ((self.csr.mie >> 1) & 1) != 0
            && ((self.csr.mip >> 1) & 1) != 0
            && ((self.csr.mideleg >> 1) & 1) != 0
        {
            self.fault_addr = 0;
            self.take_trap(0x8000_0000_0000_0001);
            return None;
        }
        // Deliver S-mode timer interrupt if delegated and enabled.
        if self.csr.mode() <= 1
            && ((self.csr.mstatus >> 1) & 1) != 0
            && ((self.csr.mie >> 5) & 1) != 0
            && ((self.csr.mip >> 5) & 1) != 0
            && ((self.csr.mideleg >> 5) & 1) != 0
        {
            self.fault_addr = 0;
            self.take_trap(0x8000_0000_0000_0005);
            return None;
        }
        // Deliver M-mode external interrupt if globally and specifically enabled.
        if self.csr.mode() == 3
            && ((self.csr.mstatus >> 3) & 1) != 0
            && ((self.csr.mie >> 11) & 1) != 0
            && ((self.csr.mip >> 11) & 1) != 0
        {
            self.fault_addr = 0;
            self.take_trap(0x8000_0000_0000_0011);
            return None;
        }
        // Deliver S-mode external interrupt if delegated and enabled.
        if self.csr.mode() <= 1
            && ((self.csr.mstatus >> 1) & 1) != 0
            && ((self.csr.mie >> 9) & 1) != 0
            && ((self.csr.mip >> 9) & 1) != 0
            && ((self.csr.mideleg >> 9) & 1) != 0
        {
            self.fault_addr = 0;
            self.take_trap(0x8000_0000_0000_0009);
            return None;
        }

        let insn = decode_with_ai(w, xlen as u32, self.ai_instr_set.as_ref());

        // Capture architectural state before execution changes it.
        let pc_rdata = pc;
        let rd_addr = self.result_reg(&insn);

        let pc_wdata = match self.execute(insn, mem, xlen) {
            Ok(pc) => pc,
            Err(ExecError::Trap(c)) => {
                self.take_trap(c);
                return None;
            }
        };

        let frd_addr = self.fresult_reg(&insn);
        let frd_wdata = if frd_addr != 0 {
            self.fregs.get(frd_addr)
        } else {
            0
        };
        self.record(
            pc_rdata,
            pc_wdata,
            w,
            false,
            0,
            false,
            rd_addr,
            self.regs.get(rd_addr),
            frd_addr,
            frd_wdata,
        );
        self.regs.pc = pc_wdata;
        self.instret += 1;
        self.clock.retire(1);
        if let Some(c) = mem.clint_mut() {
            c.tick();
            if c.timer_pending(0) {
                if (self.csr.mideleg >> 5) & 1 != 0 {
                    self.csr.mip |= 1u64 << 5;
                    self.csr.mip &= !(1u64 << 7);
                } else {
                    self.csr.mip |= 1u64 << 7;
                    self.csr.mip &= !(1u64 << 5);
                }
            } else {
                self.csr.mip &= !((1u64 << 7) | (1u64 << 5));
            }
            if c.sw_pending(0) {
                if (self.csr.mideleg >> 1) & 1 != 0 {
                    self.csr.mip |= 1u64 << 1;
                    self.csr.mip &= !(1u64 << 3);
                } else {
                    self.csr.mip |= 1u64 << 3;
                    self.csr.mip &= !(1u64 << 1);
                }
            } else {
                self.csr.mip &= !((1u64 << 3) | (1u64 << 1));
            }
        }
        if let Some(p) = mem.plic() {
            if p.any_pending(0) {
                if (self.csr.mideleg >> 9) & 1 != 0 {
                    self.csr.mip |= 1u64 << 9;
                    self.csr.mip &= !(1u64 << 11);
                } else {
                    self.csr.mip |= 1u64 << 11;
                    self.csr.mip &= !(1u64 << 9);
                }
            } else {
                self.csr.mip &= !((1u64 << 11) | (1u64 << 9));
            }
        }
        self.run_pending_ai_job(mem);
        if let Some(a) = mem.ai_island() {
            let (pending, source) = (a.irq_pending, a.irq_source);
            match source {
                // Routed: raise the island's own source so the guest claims and completes
                // it through the controller, which is the discipline the RTL requires and
                // the one an in-guest driver has to get right.
                Some(src) if pending => {
                    if let Some(p) = mem.plic_mut() {
                        p.pending |= 1u32 << src;
                    }
                }
                Some(src) => {
                    if let Some(p) = mem.plic_mut() {
                        p.pending &= !(1u32 << src);
                    }
                }
                // Unrouted: the device tree did not say which line the island drives, so
                // there is nothing to claim. Report it directly rather than inventing a
                // source id, and leave the gap visible.
                None if pending => self.csr.mip |= 1u64 << 11,
                None => {}
            }
        }

        None
    }

    /// Execute a job a doorbell write latched, and apply its memory effects.
    ///
    /// The island is a device inside `mem`, so it cannot both hold the job and write `C`.
    /// This is the seam where the two halves meet: take the job, compute against guest
    /// memory, write the results back, then report the status to the device.
    fn run_pending_ai_job(&mut self, mem: &mut PhysMem) {
        let Some(model) = self.ai_model.clone() else {
            return;
        };
        let Some(ev) = mem.ai_island_mut().and_then(|a| a.take_pending_job()) else {
            return;
        };
        let mut job = crate::gemm::execute(mem, &ev, &model);
        if Self::apply_ai_c_writes(mem, &job.c_writes).is_err() {
            job.status = crate::gemm::bad_pointer_status(&model);
        }
        let write = mem
            .ai_island_mut()
            .and_then(|a| a.complete_pending_job(ev, job.status));
        if let Some((addr, word)) = write {
            if Self::write_ai_completion(mem, addr, word).is_err() {
                if let Some(ai) = mem.ai_island_mut() {
                    ai.fail_pending_dma();
                }
            }
        }
    }

    fn apply_ai_c_writes(mem: &mut PhysMem, writes: &[(u64, i32)]) -> Result<(), MemError> {
        for (addr, _) in writes {
            if addr % 4 != 0 || !mem.is_ram_range(*addr, 4) {
                return Err(MemError::Invalid);
            }
        }
        for (addr, value) in writes {
            mem.write_le::<4>(*addr, *value as u32 as u64)?;
        }
        Ok(())
    }

    fn write_ai_completion(mem: &mut PhysMem, addr: u64, word: u64) -> Result<(), MemError> {
        if addr == 0 {
            return Ok(());
        }
        if !crate::gemm::completion_writable(mem, addr) {
            return Err(MemError::Invalid);
        }
        mem.write_le::<8>(addr, word)
    }

    /// Run until a halt or `limit` steps, comparing each retired record against a
    /// reference stream.  The first diverging record returns `Halt::ReplayDivergence`.
    pub fn run_replay(
        &mut self,
        mem: &mut PhysMem,
        xlen: u8,
        limit: u64,
        reference: &[g6q_diag::CommitRecord],
    ) -> Halt {
        for _ in 0..limit {
            if let Some(h) = self.step(mem, xlen) {
                return h;
            }
            let i = self.records.len() - 1;
            if let Some(r) = reference.get(i) {
                let d = self.records[i].diff(r);
                if !d.is_empty() {
                    return Halt::ReplayDivergence(i, d);
                }
            } else {
                // Reference ended before we did: the replay is longer.
                return Halt::ReplayDivergence(
                    i,
                    vec![g6q_diag::FieldDiff {
                        field: "stream-length".into(),
                        lhs: (i + 1).to_string(),
                        rhs: reference.len().to_string(),
                    }],
                );
            }
        }
        if self.records.len() != reference.len() {
            return Halt::ReplayDivergence(
                self.records.len(),
                vec![g6q_diag::FieldDiff {
                    field: "stream-length".into(),
                    lhs: self.records.len().to_string(),
                    rhs: reference.len().to_string(),
                }],
            );
        }
        Halt::StepLimit
    }

    /// Run until a halt or `limit` steps.
    pub fn run(&mut self, mem: &mut PhysMem, xlen: u8, limit: u64) -> Halt {
        for _ in 0..limit {
            if let Some(h) = self.step(mem, xlen) {
                return h;
            }
        }
        Halt::StepLimit
    }

    /// Capture the architectural state of this hart as a D1 checkpoint.
    pub fn checkpoint(&self, mem: &PhysMem) -> g6q_diag::Checkpoint {
        g6q_diag::Checkpoint {
            record_order: self.record_order,
            x: self.regs.to_array().to_vec(),
            pc: self.regs.pc,
            f: self.fregs.to_array().to_vec(),
            fcsr: self.csr.fflags | (self.csr.frm << 5),
            prv: self.csr.mode,
            instret: self.instret,
            reservation: self.reservation,
            fault_addr: self.fault_addr,
            csr: self
                .csr
                .to_pairs()
                .into_iter()
                .map(|(k, v)| (k.to_string(), v))
                .collect(),
            clock_instret: self.clock.instret(),
            clock_instret_per_tick: self.clock.instret_per_tick(),
            memory: mem
                .snapshot()
                .into_iter()
                .map(|(base, len, data)| g6q_diag::MemRegion {
                    base,
                    len,
                    data: data
                        .iter()
                        .fold(String::with_capacity(data.len() * 2), |mut s, b| {
                            write!(s, "{b:02x}").unwrap();
                            s
                        }),
                })
                .collect(),
            devices: mem.device_snapshots(),
        }
    }

    /// Restore hart and memory state from a checkpoint.
    pub fn restore(&mut self, mem: &mut PhysMem, cp: &g6q_diag::Checkpoint) {
        assert_eq!(cp.x.len(), 32, "checkpoint x register count");
        assert_eq!(cp.f.len(), 32, "checkpoint f register count");
        let mut xarr = [0u64; 32];
        xarr.copy_from_slice(&cp.x);
        self.regs.from_array(&xarr);
        self.regs.pc = cp.pc;
        let mut farr = [0u64; 32];
        farr.copy_from_slice(&cp.f);
        self.fregs.from_array(&farr);
        self.csr.from_pairs(&cp.csr);
        self.csr.fflags = cp.fcsr & 0x1f;
        self.csr.frm = (cp.fcsr >> 5) & 0x7;
        self.csr.mode = cp.prv;
        self.instret = cp.instret;
        self.record_order = cp.record_order;
        self.reservation = cp.reservation;
        self.fault_addr = cp.fault_addr;
        self.clock = crate::Clock::with_instret(cp.clock_instret_per_tick, cp.clock_instret);
        let decoded: Vec<(u64, u64, Vec<u8>)> = cp
            .memory
            .iter()
            .map(|r| {
                let mut data = Vec::with_capacity(r.data.len() / 2);
                for chunk in r.data.as_bytes().chunks(2) {
                    let s = std::str::from_utf8(chunk).unwrap_or("00");
                    data.push(u8::from_str_radix(s, 16).unwrap_or(0));
                }
                assert_eq!(data.len(), r.len as usize);
                (r.base, r.len, data)
            })
            .collect();
        mem.restore(&decoded);
        mem.restore_devices(&cp.devices);
    }

    fn result_reg(&self, insn: &Insn) -> u8 {
        match *insn {
            Insn::Lui { rd, .. } => rd,
            Insn::Auipc { rd, .. } => rd,
            Insn::Jal { rd, .. } => rd,
            Insn::Jalr { rd, .. } => rd,
            Insn::Lb { rd, .. }
            | Insn::Lh { rd, .. }
            | Insn::Lw { rd, .. }
            | Insn::Lbu { rd, .. }
            | Insn::Lhu { rd, .. }
            | Insn::Lwu { rd, .. }
            | Insn::Ld { rd, .. } => rd,
            Insn::Addi { rd, .. }
            | Insn::Slti { rd, .. }
            | Insn::Sltiu { rd, .. }
            | Insn::Xori { rd, .. }
            | Insn::Ori { rd, .. }
            | Insn::Andi { rd, .. }
            | Insn::Slli { rd, .. }
            | Insn::Srli { rd, .. }
            | Insn::Srai { rd, .. } => rd,
            Insn::Addiw { rd, .. }
            | Insn::Slliw { rd, .. }
            | Insn::Srliw { rd, .. }
            | Insn::Sraiw { rd, .. } => rd,
            Insn::Add { rd, .. }
            | Insn::Sub { rd, .. }
            | Insn::Sll { rd, .. }
            | Insn::Slt { rd, .. }
            | Insn::Sltu { rd, .. }
            | Insn::Xor { rd, .. }
            | Insn::Srl { rd, .. }
            | Insn::Sra { rd, .. }
            | Insn::Or { rd, .. }
            | Insn::And { rd, .. } => rd,
            Insn::Addw { rd, .. }
            | Insn::Subw { rd, .. }
            | Insn::Sllw { rd, .. }
            | Insn::Srlw { rd, .. }
            | Insn::Sraw { rd, .. } => rd,
            Insn::Csrrw { rd, .. }
            | Insn::Csrrs { rd, .. }
            | Insn::Csrrc { rd, .. }
            | Insn::Csrrwi { rd, .. }
            | Insn::Csrrsi { rd, .. }
            | Insn::Csrrci { rd, .. } => rd,
            Insn::Mul { rd, .. }
            | Insn::Mulh { rd, .. }
            | Insn::Mulhsu { rd, .. }
            | Insn::Mulhu { rd, .. }
            | Insn::Div { rd, .. }
            | Insn::Divu { rd, .. }
            | Insn::Rem { rd, .. }
            | Insn::Remu { rd, .. }
            | Insn::Mulw { rd, .. }
            | Insn::Divw { rd, .. }
            | Insn::Divuw { rd, .. }
            | Insn::Remw { rd, .. }
            | Insn::Remuw { rd, .. }
            | Insn::Sh1add { rd, .. }
            | Insn::Sh2add { rd, .. }
            | Insn::Sh3add { rd, .. }
            | Insn::AddUw { rd, .. }
            | Insn::Sh1addUw { rd, .. }
            | Insn::Sh2addUw { rd, .. }
            | Insn::Sh3addUw { rd, .. }
            | Insn::SlliUw { rd, .. }
            | Insn::Bclr { rd, .. }
            | Insn::Bext { rd, .. }
            | Insn::Binv { rd, .. }
            | Insn::Bset { rd, .. }
            | Insn::Bclri { rd, .. }
            | Insn::Bexti { rd, .. }
            | Insn::Binvi { rd, .. }
            | Insn::Bseti { rd, .. }
            | Insn::Andn { rd, .. }
            | Insn::Orn { rd, .. }
            | Insn::Xnor { rd, .. }
            | Insn::Clz { rd, .. }
            | Insn::Ctz { rd, .. }
            | Insn::Cpop { rd, .. }
            | Insn::Clzw { rd, .. }
            | Insn::Ctzw { rd, .. }
            | Insn::Cpopw { rd, .. }
            | Insn::Min { rd, .. }
            | Insn::Minu { rd, .. }
            | Insn::Max { rd, .. }
            | Insn::Maxu { rd, .. }
            | Insn::Rol { rd, .. }
            | Insn::Ror { rd, .. }
            | Insn::Rori { rd, .. }
            | Insn::Rolw { rd, .. }
            | Insn::Rorw { rd, .. }
            | Insn::Roriw { rd, .. }
            | Insn::Rev8 { rd, .. }
            | Insn::OrcB { rd, .. }
            | Insn::SextB { rd, .. }
            | Insn::SextH { rd, .. }
            | Insn::ZextH { rd, .. }
            | Insn::FcvtWS { rd, .. }
            | Insn::FcvtWuS { rd, .. }
            | Insn::FcvtLS { rd, .. }
            | Insn::FcvtLuS { rd, .. }
            | Insn::FmvXW { rd, .. }
            | Insn::FeqS { rd, .. }
            | Insn::FltS { rd, .. }
            | Insn::FleS { rd, .. }
            | Insn::FclassS { rd, .. }
            | Insn::FcvtWD { rd, .. }
            | Insn::FcvtWuD { rd, .. }
            | Insn::FcvtLD { rd, .. }
            | Insn::FcvtLuD { rd, .. }
            | Insn::FmvXD { rd, .. }
            | Insn::FeqD { rd, .. }
            | Insn::FltD { rd, .. }
            | Insn::FleD { rd, .. }
            | Insn::FclassD { rd, .. } => rd,
            Insn::LrW { rd, .. }
            | Insn::LrD { rd, .. }
            | Insn::ScW { rd, .. }
            | Insn::ScD { rd, .. }
            | Insn::AmoaddW { rd, .. }
            | Insn::AmoaddD { rd, .. }
            | Insn::AmoswapW { rd, .. }
            | Insn::AmoswapD { rd, .. }
            | Insn::AmoxorW { rd, .. }
            | Insn::AmoxorD { rd, .. }
            | Insn::AmoorW { rd, .. }
            | Insn::AmoorD { rd, .. }
            | Insn::AmoandW { rd, .. }
            | Insn::AmoandD { rd, .. }
            | Insn::AmominW { rd, .. }
            | Insn::AmominD { rd, .. }
            | Insn::AmomaxW { rd, .. }
            | Insn::AmomaxD { rd, .. }
            | Insn::AmominuW { rd, .. }
            | Insn::AmominuD { rd, .. }
            | Insn::AmomaxuW { rd, .. }
            | Insn::AmomaxuD { rd, .. }
            | Insn::AmocasW { rd, .. }
            | Insn::AmocasD { rd, .. } => rd,
            _ => 0,
        }
    }

    fn fresult_reg(&self, insn: &Insn) -> u8 {
        // Returns the FP destination register for FP-writing instructions.
        match *insn {
            Insn::Flw { rd, .. }
            | Insn::Fld { rd, .. }
            | Insn::FmaddS { rd, .. }
            | Insn::FmsubS { rd, .. }
            | Insn::FnmsubS { rd, .. }
            | Insn::FnmaddS { rd, .. }
            | Insn::FmaddD { rd, .. }
            | Insn::FmsubD { rd, .. }
            | Insn::FnmsubD { rd, .. }
            | Insn::FnmaddD { rd, .. }
            | Insn::FaddS { rd, .. }
            | Insn::FsubS { rd, .. }
            | Insn::FmulS { rd, .. }
            | Insn::FdivS { rd, .. }
            | Insn::FsqrtS { rd, .. }
            | Insn::FaddD { rd, .. }
            | Insn::FsubD { rd, .. }
            | Insn::FmulD { rd, .. }
            | Insn::FdivD { rd, .. }
            | Insn::FsqrtD { rd, .. }
            | Insn::FsgnjS { rd, .. }
            | Insn::FsgnjnS { rd, .. }
            | Insn::FsgnjxS { rd, .. }
            | Insn::FsgnjD { rd, .. }
            | Insn::FsgnjnD { rd, .. }
            | Insn::FsgnjxD { rd, .. }
            | Insn::FminS { rd, .. }
            | Insn::FmaxS { rd, .. }
            | Insn::FminD { rd, .. }
            | Insn::FmaxD { rd, .. }
            | Insn::FcvtSW { rd, .. }
            | Insn::FcvtSWu { rd, .. }
            | Insn::FcvtSL { rd, .. }
            | Insn::FcvtSLu { rd, .. }
            | Insn::FcvtDW { rd, .. }
            | Insn::FcvtDWu { rd, .. }
            | Insn::FcvtDL { rd, .. }
            | Insn::FcvtDLu { rd, .. }
            | Insn::FcvtSD { rd, .. }
            | Insn::FcvtDS { rd, .. }
            | Insn::FmvWX { rd, .. }
            | Insn::FmvDX { rd, .. } => rd,
            _ => 0,
        }
    }

    /// Read an AI queue CSR if the model provides one and the island is installed.
    ///
    /// Returns `Some(value)` for `aiqbase`/`aiqctl`/`aiqhead`, `None` for all other CSR numbers
    /// so the standard `CsrBank` keeps control of the rest of the CSR space.
    fn ai_queue_csr_read(&self, mem: &PhysMem, csr: u16) -> Option<u64> {
        let set = self.ai_instr_set.as_ref()?;
        if set.csr_aiqbase == 0 && set.csr_aiqctl == 0 && set.csr_aiqhead == 0 {
            return None;
        }
        if csr != set.csr_aiqbase && csr != set.csr_aiqctl && csr != set.csr_aiqhead {
            return None;
        }
        mem.ai_island()?.queue_csr_read(self.csr.hartid as u32, csr)
    }

    /// Write an AI queue CSR if the model provides one and the island is installed.
    fn ai_queue_csr_write(&mut self, mem: &mut PhysMem, csr: u16, value: u64) -> Option<u64> {
        let set = self.ai_instr_set.as_ref()?;
        if set.csr_aiqbase == 0 && set.csr_aiqctl == 0 && set.csr_aiqhead == 0 {
            return None;
        }
        if csr != set.csr_aiqbase && csr != set.csr_aiqctl && csr != set.csr_aiqhead {
            return None;
        }
        mem.ai_island_mut()?
            .queue_csr_write(self.csr.hartid as u32, csr, value)
    }

    fn execute(&mut self, insn: Insn, mem: &mut PhysMem, xlen: u8) -> Result<u64, ExecError> {
        let nx = self.regs.pc.wrapping_add(self.inst_len as u64);
        // For variable shifts the mask depends on XLEN; 32-bit words always use 5 bits.
        let sh_mask = if xlen == 64 { 0x3f } else { 0x1f };
        match insn {
            Insn::Lui { rd, imm } => {
                self.regs.set(rd, imm as u64);
                Ok(nx)
            }
            Insn::Auipc { rd, imm } => {
                self.regs.set(rd, self.regs.pc.wrapping_add(imm as u64));
                Ok(nx)
            }
            Insn::Jal { rd, imm } => {
                self.regs.set(rd, nx);
                Ok(self.regs.pc.wrapping_add(imm as u64))
            }
            Insn::Jalr { rd, rs1, imm } => {
                let target = self.regs.get(rs1).wrapping_add(imm as u64) & !1u64;
                self.regs.set(rd, nx);
                Ok(target)
            }
            Insn::Beq { rs1, rs2, imm } => {
                if self.regs.get(rs1) == self.regs.get(rs2) {
                    Ok(self.regs.pc.wrapping_add(imm as u64))
                } else {
                    Ok(nx)
                }
            }
            Insn::Bne { rs1, rs2, imm } => {
                if self.regs.get(rs1) != self.regs.get(rs2) {
                    Ok(self.regs.pc.wrapping_add(imm as u64))
                } else {
                    Ok(nx)
                }
            }
            Insn::Blt { rs1, rs2, imm } => {
                if (self.regs.get(rs1) as i64) < (self.regs.get(rs2) as i64) {
                    Ok(self.regs.pc.wrapping_add(imm as u64))
                } else {
                    Ok(nx)
                }
            }
            Insn::Bge { rs1, rs2, imm } => {
                if (self.regs.get(rs1) as i64) >= (self.regs.get(rs2) as i64) {
                    Ok(self.regs.pc.wrapping_add(imm as u64))
                } else {
                    Ok(nx)
                }
            }
            Insn::Bltu { rs1, rs2, imm } => {
                if self.regs.get(rs1) < self.regs.get(rs2) {
                    Ok(self.regs.pc.wrapping_add(imm as u64))
                } else {
                    Ok(nx)
                }
            }
            Insn::Bgeu { rs1, rs2, imm } => {
                if self.regs.get(rs1) >= self.regs.get(rs2) {
                    Ok(self.regs.pc.wrapping_add(imm as u64))
                } else {
                    Ok(nx)
                }
            }
            Insn::Lb { rd, rs1, imm } => {
                let addr = self.regs.get(rs1).wrapping_add(imm as u64);
                let v = self.load_sext::<1>(mem, addr)?;
                self.regs.set(rd, v as u64);
                Ok(nx)
            }
            Insn::Lh { rd, rs1, imm } => {
                let addr = self.regs.get(rs1).wrapping_add(imm as u64);
                let v = self.load_sext::<2>(mem, addr)?;
                self.regs.set(rd, v as u64);
                Ok(nx)
            }
            Insn::Lw { rd, rs1, imm } => {
                let addr = self.regs.get(rs1).wrapping_add(imm as u64);
                let v = self.load_sext::<4>(mem, addr)?;
                self.regs.set(rd, v as u64);
                Ok(nx)
            }
            Insn::Lbu { rd, rs1, imm } => {
                let addr = self.regs.get(rs1).wrapping_add(imm as u64);
                let v = self.load_le::<1>(mem, addr)?;
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Lhu { rd, rs1, imm } => {
                let addr = self.regs.get(rs1).wrapping_add(imm as u64);
                let v = self.load_le::<2>(mem, addr)?;
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Lwu { rd, rs1, imm } => {
                let addr = self.regs.get(rs1).wrapping_add(imm as u64);
                let v = self.load_le::<4>(mem, addr)?;
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Ld { rd, rs1, imm } => {
                let addr = self.regs.get(rs1).wrapping_add(imm as u64);
                let v = self.load_le::<8>(mem, addr)?;
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Sb { rs1, rs2, imm } => {
                let addr = self.regs.get(rs1).wrapping_add(imm as u64);
                self.store_le::<1>(mem, addr, self.regs.get(rs2))?;
                Ok(nx)
            }
            Insn::Sh { rs1, rs2, imm } => {
                let addr = self.regs.get(rs1).wrapping_add(imm as u64);
                self.store_le::<2>(mem, addr, self.regs.get(rs2))?;
                Ok(nx)
            }
            Insn::Sw { rs1, rs2, imm } => {
                let addr = self.regs.get(rs1).wrapping_add(imm as u64);
                self.store_le::<4>(mem, addr, self.regs.get(rs2))?;
                Ok(nx)
            }
            Insn::Sd { rs1, rs2, imm } => {
                let addr = self.regs.get(rs1).wrapping_add(imm as u64);
                self.store_le::<8>(mem, addr, self.regs.get(rs2))?;
                Ok(nx)
            }
            Insn::Addi { rd, rs1, imm } => {
                self.regs
                    .set(rd, self.regs.get(rs1).wrapping_add(imm as u64));
                Ok(nx)
            }
            Insn::Slti { rd, rs1, imm } => {
                self.regs.set(
                    rd,
                    if (self.regs.get(rs1) as i64) < imm {
                        1
                    } else {
                        0
                    },
                );
                Ok(nx)
            }
            Insn::Sltiu { rd, rs1, imm } => {
                self.regs.set(
                    rd,
                    if self.regs.get(rs1) < (imm as u64) {
                        1
                    } else {
                        0
                    },
                );
                Ok(nx)
            }
            Insn::Xori { rd, rs1, imm } => {
                self.regs.set(rd, self.regs.get(rs1) ^ (imm as u64));
                Ok(nx)
            }
            Insn::Ori { rd, rs1, imm } => {
                self.regs.set(rd, self.regs.get(rs1) | (imm as u64));
                Ok(nx)
            }
            Insn::Andi { rd, rs1, imm } => {
                self.regs.set(rd, self.regs.get(rs1) & (imm as u64));
                Ok(nx)
            }
            Insn::Slli { rd, rs1, shamt } => {
                self.regs.set(rd, self.regs.get(rs1) << shamt);
                Ok(nx)
            }
            Insn::Srli { rd, rs1, shamt } => {
                self.regs.set(rd, self.regs.get(rs1) >> shamt);
                Ok(nx)
            }
            Insn::Srai { rd, rs1, shamt } => {
                self.regs
                    .set(rd, ((self.regs.get(rs1) as i64) >> shamt) as u64);
                Ok(nx)
            }
            Insn::Addiw { rd, rs1, imm } => {
                let v = (self.regs.get(rs1) as i64).wrapping_add(imm as i64) as i32;
                self.regs.set(rd, v as i64 as u64);
                Ok(nx)
            }
            Insn::Slliw { rd, rs1, shamt } => {
                let v = (self.regs.get(rs1) as u32) << shamt;
                self.regs.set(rd, (v as i32) as i64 as u64);
                Ok(nx)
            }
            Insn::Srliw { rd, rs1, shamt } => {
                let v = (self.regs.get(rs1) as u32) >> shamt;
                self.regs.set(rd, (v as i32) as i64 as u64);
                Ok(nx)
            }
            Insn::Sraiw { rd, rs1, shamt } => {
                let v = ((self.regs.get(rs1) as u32) as i32) >> shamt;
                self.regs.set(rd, (v as i64) as u64);
                Ok(nx)
            }
            Insn::Add { rd, rs1, rs2 } => {
                self.regs
                    .set(rd, self.regs.get(rs1).wrapping_add(self.regs.get(rs2)));
                Ok(nx)
            }
            Insn::Sub { rd, rs1, rs2 } => {
                self.regs
                    .set(rd, self.regs.get(rs1).wrapping_sub(self.regs.get(rs2)));
                Ok(nx)
            }
            Insn::Sll { rd, rs1, rs2 } => {
                let sh = self.regs.get(rs2) & sh_mask;
                self.regs.set(rd, self.regs.get(rs1) << sh);
                Ok(nx)
            }
            Insn::Slt { rd, rs1, rs2 } => {
                self.regs.set(
                    rd,
                    if (self.regs.get(rs1) as i64) < (self.regs.get(rs2) as i64) {
                        1
                    } else {
                        0
                    },
                );
                Ok(nx)
            }
            Insn::Sltu { rd, rs1, rs2 } => {
                self.regs.set(
                    rd,
                    if self.regs.get(rs1) < self.regs.get(rs2) {
                        1
                    } else {
                        0
                    },
                );
                Ok(nx)
            }
            Insn::Xor { rd, rs1, rs2 } => {
                self.regs.set(rd, self.regs.get(rs1) ^ self.regs.get(rs2));
                Ok(nx)
            }
            Insn::Srl { rd, rs1, rs2 } => {
                let sh = self.regs.get(rs2) & sh_mask;
                self.regs.set(rd, self.regs.get(rs1) >> sh);
                Ok(nx)
            }
            Insn::Sra { rd, rs1, rs2 } => {
                let sh = self.regs.get(rs2) & sh_mask;
                self.regs
                    .set(rd, ((self.regs.get(rs1) as i64) >> sh) as u64);
                Ok(nx)
            }
            Insn::Or { rd, rs1, rs2 } => {
                self.regs.set(rd, self.regs.get(rs1) | self.regs.get(rs2));
                Ok(nx)
            }
            Insn::And { rd, rs1, rs2 } => {
                self.regs.set(rd, self.regs.get(rs1) & self.regs.get(rs2));
                Ok(nx)
            }
            Insn::Addw { rd, rs1, rs2 } => {
                let v = (self.regs.get(rs1) as i64).wrapping_add(self.regs.get(rs2) as i64) as i32;
                self.regs.set(rd, (v as i64) as u64);
                Ok(nx)
            }
            Insn::Subw { rd, rs1, rs2 } => {
                let v = (self.regs.get(rs1) as i64).wrapping_sub(self.regs.get(rs2) as i64) as i32;
                self.regs.set(rd, (v as i64) as u64);
                Ok(nx)
            }
            Insn::Sllw { rd, rs1, rs2 } => {
                let sh = self.regs.get(rs2) & 0x1f;
                let v = (self.regs.get(rs1) as u32) << sh;
                self.regs.set(rd, (v as i32) as i64 as u64);
                Ok(nx)
            }
            Insn::Srlw { rd, rs1, rs2 } => {
                let sh = self.regs.get(rs2) & 0x1f;
                let v = (self.regs.get(rs1) as u32) >> sh;
                self.regs.set(rd, (v as i32) as i64 as u64);
                Ok(nx)
            }
            Insn::Sraw { rd, rs1, rs2 } => {
                let sh = self.regs.get(rs2) & 0x1f;
                let v = ((self.regs.get(rs1) as u32) as i32) >> sh;
                self.regs.set(rd, (v as i64) as u64);
                Ok(nx)
            }
            Insn::Mul { rd, rs1, rs2 } => {
                self.regs
                    .set(rd, self.regs.get(rs1).wrapping_mul(self.regs.get(rs2)));
                Ok(nx)
            }
            Insn::Mulh { rd, rs1, rs2 } => {
                let p = (self.regs.get(rs1) as i128).wrapping_mul(self.regs.get(rs2) as i128);
                self.regs.set(rd, (p >> 64) as u64);
                Ok(nx)
            }
            Insn::Mulhsu { rd, rs1, rs2 } => {
                let p =
                    (self.regs.get(rs1) as i128).wrapping_mul(self.regs.get(rs2) as u128 as i128);
                self.regs.set(rd, (p >> 64) as u64);
                Ok(nx)
            }
            Insn::Mulhu { rd, rs1, rs2 } => {
                let p = (self.regs.get(rs1) as u128).wrapping_mul(self.regs.get(rs2) as u128);
                self.regs.set(rd, (p >> 64) as u64);
                Ok(nx)
            }
            Insn::Div { rd, rs1, rs2 } => {
                let a = self.regs.get(rs1) as i64;
                let b = self.regs.get(rs2) as i64;
                let v = if b == 0 {
                    -1i64 as u64
                } else if a == i64::MIN && b == -1 {
                    a as u64
                } else {
                    (a / b) as u64
                };
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Divu { rd, rs1, rs2 } => {
                let a = self.regs.get(rs1);
                let b = self.regs.get(rs2);
                let v = if b == 0 { u64::MAX } else { a / b };
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Rem { rd, rs1, rs2 } => {
                let a = self.regs.get(rs1) as i64;
                let b = self.regs.get(rs2) as i64;
                let v = if b == 0 {
                    a as u64
                } else if a == i64::MIN && b == -1 {
                    0
                } else {
                    (a % b) as u64
                };
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Remu { rd, rs1, rs2 } => {
                let a = self.regs.get(rs1);
                let b = self.regs.get(rs2);
                let v = if b == 0 { a } else { a % b };
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Mulw { rd, rs1, rs2 } => {
                let v = (self.regs.get(rs1) as i32).wrapping_mul(self.regs.get(rs2) as i32);
                self.regs.set(rd, (v as i64) as u64);
                Ok(nx)
            }
            Insn::Divw { rd, rs1, rs2 } => {
                let a = self.regs.get(rs1) as i32;
                let b = self.regs.get(rs2) as i32;
                let v: u32 = if b == 0 {
                    u32::MAX
                } else if a == i32::MIN && b == -1 {
                    a as u32
                } else {
                    (a / b) as u32
                };
                self.regs.set(rd, (v as i32 as i64) as u64);
                Ok(nx)
            }
            Insn::Divuw { rd, rs1, rs2 } => {
                let a = self.regs.get(rs1) as u32;
                let b = self.regs.get(rs2) as u32;
                let v = if b == 0 { u32::MAX } else { a / b };
                self.regs.set(rd, (v as i32 as i64) as u64);
                Ok(nx)
            }
            Insn::Remw { rd, rs1, rs2 } => {
                let a = self.regs.get(rs1) as i32;
                let b = self.regs.get(rs2) as i32;
                let v: u32 = if b == 0 {
                    a as u32
                } else if a == i32::MIN && b == -1 {
                    0
                } else {
                    (a % b) as u32
                };
                self.regs.set(rd, (v as i32 as i64) as u64);
                Ok(nx)
            }
            Insn::Remuw { rd, rs1, rs2 } => {
                let a = self.regs.get(rs1) as u32;
                let b = self.regs.get(rs2) as u32;
                let v = if b == 0 { a } else { a % b };
                self.regs.set(rd, (v as i32 as i64) as u64);
                Ok(nx)
            }

            Insn::Sh1add { rd, rs1, rs2 } => {
                let v = self.regs.get(rs1).wrapping_add(self.regs.get(rs2) << 1);
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Sh2add { rd, rs1, rs2 } => {
                let v = self.regs.get(rs1).wrapping_add(self.regs.get(rs2) << 2);
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Sh3add { rd, rs1, rs2 } => {
                let v = self.regs.get(rs1).wrapping_add(self.regs.get(rs2) << 3);
                self.regs.set(rd, v);
                Ok(nx)
            }

            Insn::AddUw { rd, rs1, rs2 } => {
                let v = self
                    .regs
                    .get(rs2)
                    .wrapping_add(self.regs.get(rs1) as u32 as u64);
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Sh1addUw { rd, rs1, rs2 } => {
                let v = self
                    .regs
                    .get(rs2)
                    .wrapping_add((self.regs.get(rs1) as u32 as u64) << 1);
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Sh2addUw { rd, rs1, rs2 } => {
                let v = self
                    .regs
                    .get(rs2)
                    .wrapping_add((self.regs.get(rs1) as u32 as u64) << 2);
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Sh3addUw { rd, rs1, rs2 } => {
                let v = self
                    .regs
                    .get(rs2)
                    .wrapping_add((self.regs.get(rs1) as u32 as u64) << 3);
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::SlliUw { rd, rs1, shamt } => {
                let v = (self.regs.get(rs1) as u32 as u64) << (shamt & 0x3f);
                self.regs.set(rd, v);
                Ok(nx)
            }

            Insn::Bclr { rd, rs1, rs2 } => {
                let sh = (self.regs.get(rs2) & 0x3f) as u32;
                let v = self.regs.get(rs1) & !(1u64 << sh);
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Bext { rd, rs1, rs2 } => {
                let sh = (self.regs.get(rs2) & 0x3f) as u32;
                let v = (self.regs.get(rs1) >> sh) & 1;
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Binv { rd, rs1, rs2 } => {
                let sh = (self.regs.get(rs2) & 0x3f) as u32;
                let v = self.regs.get(rs1) ^ (1u64 << sh);
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Bset { rd, rs1, rs2 } => {
                let sh = (self.regs.get(rs2) & 0x3f) as u32;
                let v = self.regs.get(rs1) | (1u64 << sh);
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Bclri { rd, rs1, shamt } => {
                let sh = (shamt & 0x3f) as u32;
                let v = self.regs.get(rs1) & !(1u64 << sh);
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Bexti { rd, rs1, shamt } => {
                let sh = (shamt & 0x3f) as u32;
                let v = (self.regs.get(rs1) >> sh) & 1;
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Binvi { rd, rs1, shamt } => {
                let sh = (shamt & 0x3f) as u32;
                let v = self.regs.get(rs1) ^ (1u64 << sh);
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Bseti { rd, rs1, shamt } => {
                let sh = (shamt & 0x3f) as u32;
                let v = self.regs.get(rs1) | (1u64 << sh);
                self.regs.set(rd, v);
                Ok(nx)
            }

            // Zbb (basic bit-manipulation)
            Insn::Andn { rd, rs1, rs2 } => {
                self.regs.set(rd, self.regs.get(rs1) & !self.regs.get(rs2));
                Ok(nx)
            }
            Insn::Orn { rd, rs1, rs2 } => {
                self.regs.set(rd, self.regs.get(rs1) | !self.regs.get(rs2));
                Ok(nx)
            }
            Insn::Xnor { rd, rs1, rs2 } => {
                self.regs
                    .set(rd, !(self.regs.get(rs1) ^ self.regs.get(rs2)));
                Ok(nx)
            }
            Insn::Clz { rd, rs1 } => {
                self.regs.set(rd, self.regs.get(rs1).leading_zeros() as u64);
                Ok(nx)
            }
            Insn::Ctz { rd, rs1 } => {
                self.regs
                    .set(rd, self.regs.get(rs1).trailing_zeros() as u64);
                Ok(nx)
            }
            Insn::Cpop { rd, rs1 } => {
                self.regs.set(rd, self.regs.get(rs1).count_ones() as u64);
                Ok(nx)
            }
            Insn::Clzw { rd, rs1 } => {
                self.regs
                    .set(rd, (self.regs.get(rs1) as u32).leading_zeros() as u64);
                Ok(nx)
            }
            Insn::Ctzw { rd, rs1 } => {
                self.regs
                    .set(rd, (self.regs.get(rs1) as u32).trailing_zeros() as u64);
                Ok(nx)
            }
            Insn::Cpopw { rd, rs1 } => {
                self.regs
                    .set(rd, (self.regs.get(rs1) as u32).count_ones() as u64);
                Ok(nx)
            }
            Insn::Min { rd, rs1, rs2 } => {
                let a = self.regs.get(rs1) as i64;
                let b = self.regs.get(rs2) as i64;
                self.regs.set(rd, if a < b { a as u64 } else { b as u64 });
                Ok(nx)
            }
            Insn::Minu { rd, rs1, rs2 } => {
                let a = self.regs.get(rs1);
                let b = self.regs.get(rs2);
                self.regs.set(rd, if a < b { a } else { b });
                Ok(nx)
            }
            Insn::Max { rd, rs1, rs2 } => {
                let a = self.regs.get(rs1) as i64;
                let b = self.regs.get(rs2) as i64;
                self.regs.set(rd, if a > b { a as u64 } else { b as u64 });
                Ok(nx)
            }
            Insn::Maxu { rd, rs1, rs2 } => {
                let a = self.regs.get(rs1);
                let b = self.regs.get(rs2);
                self.regs.set(rd, if a > b { a } else { b });
                Ok(nx)
            }
            Insn::Rol { rd, rs1, rs2 } => {
                let sh = (self.regs.get(rs2) & sh_mask) as u32;
                let v = if xlen == 64 {
                    self.regs.get(rs1).rotate_left(sh)
                } else {
                    ((self.regs.get(rs1) as u32).rotate_left(sh) as i32) as i64 as u64
                };
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Ror { rd, rs1, rs2 } => {
                let sh = (self.regs.get(rs2) & sh_mask) as u32;
                let v = if xlen == 64 {
                    self.regs.get(rs1).rotate_right(sh)
                } else {
                    ((self.regs.get(rs1) as u32).rotate_right(sh) as i32) as i64 as u64
                };
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Rori { rd, rs1, shamt } => {
                let sh = (shamt as u64) & sh_mask;
                let v = if xlen == 64 {
                    self.regs.get(rs1).rotate_right(sh as u32)
                } else {
                    ((self.regs.get(rs1) as u32).rotate_right(sh as u32) as i32) as i64 as u64
                };
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Rolw { rd, rs1, rs2 } => {
                let sh = self.regs.get(rs2) & 0x1f;
                let v = (self.regs.get(rs1) as u32).rotate_left(sh as u32) as i32 as i64 as u64;
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Rorw { rd, rs1, rs2 } => {
                let sh = self.regs.get(rs2) & 0x1f;
                let v = (self.regs.get(rs1) as u32).rotate_right(sh as u32) as i32 as i64 as u64;
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Roriw { rd, rs1, shamt } => {
                let sh = (shamt as u64) & 0x1f;
                let v = (self.regs.get(rs1) as u32).rotate_right(sh as u32) as i32 as i64 as u64;
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Rev8 { rd, rs1 } => {
                let v = self.regs.get(rs1);
                let r = if xlen == 64 {
                    v.to_be()
                } else {
                    (v as u32).to_be() as u64
                };
                self.regs.set(rd, r);
                Ok(nx)
            }
            Insn::OrcB { rd, rs1 } => {
                let v = self.regs.get(rs1);
                let bytes = if xlen == 64 { 8 } else { 4 };
                let mut r = 0u64;
                for i in 0..bytes {
                    let b = (v >> (i * 8)) & 0xff;
                    if b != 0 {
                        r |= 0xff << (i * 8);
                    }
                }
                self.regs.set(rd, r);
                Ok(nx)
            }
            Insn::SextB { rd, rs1 } => {
                let v = self.regs.get(rs1) as i8 as i64 as u64;
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::SextH { rd, rs1 } => {
                let v = self.regs.get(rs1) as i16 as i64 as u64;
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::ZextH { rd, rs1 } => {
                self.regs.set(rd, self.regs.get(rs1) & 0xffff);
                Ok(nx)
            }

            Insn::LrW { rd, rs1, .. } => {
                let addr = self.regs.get(rs1);
                let v = self.load_sext::<4>(mem, addr)?;
                self.reservation = Some(addr);
                self.regs.set(rd, v as u64);
                Ok(nx)
            }
            Insn::LrD { rd, rs1, .. } => {
                let addr = self.regs.get(rs1);
                let v = self.load_le::<8>(mem, addr)?;
                self.reservation = Some(addr);
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::ScW { rd, rs1, rs2, .. } => {
                let addr = self.regs.get(rs1);
                if self.reservation == Some(addr) {
                    self.store_le::<4>(mem, addr, self.regs.get(rs2))?;
                    self.regs.set(rd, 0);
                } else {
                    self.regs.set(rd, 1);
                }
                self.reservation = None;
                Ok(nx)
            }
            Insn::ScD { rd, rs1, rs2, .. } => {
                let addr = self.regs.get(rs1);
                if self.reservation == Some(addr) {
                    self.store_le::<8>(mem, addr, self.regs.get(rs2))?;
                    self.regs.set(rd, 0);
                } else {
                    self.regs.set(rd, 1);
                }
                self.reservation = None;
                Ok(nx)
            }
            Insn::AmoaddW { rd, rs1, rs2, .. } => self.amo::<4, _>(mem, rd, rs1, rs2, |a, b| {
                (a as u32).wrapping_add(b as u32) as u64
            }),
            Insn::AmoswapW { rd, rs1, rs2, .. } => {
                self.amo::<4, _>(mem, rd, rs1, rs2, |_a, b| b as u32 as u64)
            }
            Insn::AmoxorW { rd, rs1, rs2, .. } => {
                self.amo::<4, _>(mem, rd, rs1, rs2, |a, b| ((a as u32) ^ (b as u32)) as u64)
            }
            Insn::AmoorW { rd, rs1, rs2, .. } => {
                self.amo::<4, _>(mem, rd, rs1, rs2, |a, b| ((a as u32) | (b as u32)) as u64)
            }
            Insn::AmoandW { rd, rs1, rs2, .. } => {
                self.amo::<4, _>(mem, rd, rs1, rs2, |a, b| ((a as u32) & (b as u32)) as u64)
            }
            Insn::AmominW { rd, rs1, rs2, .. } => {
                self.amo::<4, _>(mem, rd, rs1, rs2, |a, b| (a as i32).min(b as i32) as u64)
            }
            Insn::AmomaxW { rd, rs1, rs2, .. } => {
                self.amo::<4, _>(mem, rd, rs1, rs2, |a, b| (a as i32).max(b as i32) as u64)
            }
            Insn::AmominuW { rd, rs1, rs2, .. } => {
                self.amo::<4, _>(mem, rd, rs1, rs2, |a, b| (a as u32).min(b as u32) as u64)
            }
            Insn::AmomaxuW { rd, rs1, rs2, .. } => {
                self.amo::<4, _>(mem, rd, rs1, rs2, |a, b| (a as u32).max(b as u32) as u64)
            }
            Insn::AmoaddD { rd, rs1, rs2, .. } => {
                self.amo::<8, _>(mem, rd, rs1, rs2, |a, b| a.wrapping_add(b))
            }
            Insn::AmoswapD { rd, rs1, rs2, .. } => self.amo::<8, _>(mem, rd, rs1, rs2, |_a, b| b),
            Insn::AmoxorD { rd, rs1, rs2, .. } => self.amo::<8, _>(mem, rd, rs1, rs2, |a, b| a ^ b),
            Insn::AmoorD { rd, rs1, rs2, .. } => self.amo::<8, _>(mem, rd, rs1, rs2, |a, b| a | b),
            Insn::AmoandD { rd, rs1, rs2, .. } => self.amo::<8, _>(mem, rd, rs1, rs2, |a, b| a & b),
            Insn::AmominD { rd, rs1, rs2, .. } => {
                self.amo::<8, _>(mem, rd, rs1, rs2, |a, b| (a as i64).min(b as i64) as u64)
            }
            Insn::AmomaxD { rd, rs1, rs2, .. } => {
                self.amo::<8, _>(mem, rd, rs1, rs2, |a, b| (a as i64).max(b as i64) as u64)
            }
            Insn::AmominuD { rd, rs1, rs2, .. } => {
                self.amo::<8, _>(mem, rd, rs1, rs2, |a, b| a.min(b))
            }
            Insn::AmomaxuD { rd, rs1, rs2, .. } => {
                self.amo::<8, _>(mem, rd, rs1, rs2, |a, b| a.max(b))
            }

            Insn::AmocasW { rd, rs1, rs2, .. } => self.amocas::<4>(mem, rd, rs1, rs2),
            Insn::AmocasD { rd, rs1, rs2, .. } => self.amocas::<8>(mem, rd, rs1, rs2),

            Insn::Fence | Insn::FenceI => Ok(nx),
            Insn::Csrrw { rd, rs1, csr } => {
                if let Some(old) = self.ai_queue_csr_read(mem, csr) {
                    let new = self.regs.get(rs1);
                    self.ai_queue_csr_write(mem, csr, new);
                    self.regs.set(rd, old);
                    return Ok(nx);
                }
                let old = self.csr.read(csr).map_err(|_| {
                    self.fault_addr = 0;
                    ExecError::Trap(2)
                })?;
                let new = self.regs.get(rs1);
                self.csr.write(csr, new).map_err(|_| {
                    self.fault_addr = 0;
                    ExecError::Trap(2)
                })?;
                self.regs.set(rd, old);
                Ok(nx)
            }
            Insn::Csrrs { rd, rs1, csr } => {
                if let Some(old) = self.ai_queue_csr_read(mem, csr) {
                    let new = if rs1 != 0 {
                        old | self.regs.get(rs1)
                    } else {
                        old
                    };
                    self.ai_queue_csr_write(mem, csr, new);
                    self.regs.set(rd, old);
                    return Ok(nx);
                }
                let old = self.csr.read(csr).map_err(|_| {
                    self.fault_addr = 0;
                    ExecError::Trap(2)
                })?;
                if rs1 != 0 {
                    self.csr.read_set(csr, self.regs.get(rs1)).map_err(|_| {
                        self.fault_addr = 0;
                        ExecError::Trap(2)
                    })?;
                }
                self.regs.set(rd, old);
                Ok(nx)
            }
            Insn::Csrrc { rd, rs1, csr } => {
                if let Some(old) = self.ai_queue_csr_read(mem, csr) {
                    let new = if rs1 != 0 {
                        old & !self.regs.get(rs1)
                    } else {
                        old
                    };
                    self.ai_queue_csr_write(mem, csr, new);
                    self.regs.set(rd, old);
                    return Ok(nx);
                }
                let old = self.csr.read(csr).map_err(|_| {
                    self.fault_addr = 0;
                    ExecError::Trap(2)
                })?;
                if rs1 != 0 {
                    self.csr.read_clear(csr, self.regs.get(rs1)).map_err(|_| {
                        self.fault_addr = 0;
                        ExecError::Trap(2)
                    })?;
                }
                self.regs.set(rd, old);
                Ok(nx)
            }
            Insn::Csrrwi { rd, uimm, csr } => {
                if let Some(old) = self.ai_queue_csr_read(mem, csr) {
                    self.ai_queue_csr_write(mem, csr, uimm as u64);
                    self.regs.set(rd, old);
                    return Ok(nx);
                }
                let old = self.csr.read(csr).map_err(|_| {
                    self.fault_addr = 0;
                    ExecError::Trap(2)
                })?;
                self.csr.write(csr, uimm as u64).map_err(|_| {
                    self.fault_addr = 0;
                    ExecError::Trap(2)
                })?;
                self.regs.set(rd, old);
                Ok(nx)
            }
            Insn::Csrrsi { rd, uimm, csr } => {
                if let Some(old) = self.ai_queue_csr_read(mem, csr) {
                    let new = if uimm != 0 { old | uimm as u64 } else { old };
                    self.ai_queue_csr_write(mem, csr, new);
                    self.regs.set(rd, old);
                    return Ok(nx);
                }
                let old = self.csr.read(csr).map_err(|_| {
                    self.fault_addr = 0;
                    ExecError::Trap(2)
                })?;
                if uimm != 0 {
                    self.csr.read_set(csr, uimm as u64).map_err(|_| {
                        self.fault_addr = 0;
                        ExecError::Trap(2)
                    })?;
                }
                self.regs.set(rd, old);
                Ok(nx)
            }
            Insn::Csrrci { rd, uimm, csr } => {
                if let Some(old) = self.ai_queue_csr_read(mem, csr) {
                    let new = if uimm != 0 { old & !(uimm as u64) } else { old };
                    self.ai_queue_csr_write(mem, csr, new);
                    self.regs.set(rd, old);
                    return Ok(nx);
                }
                let old = self.csr.read(csr).map_err(|_| {
                    self.fault_addr = 0;
                    ExecError::Trap(2)
                })?;
                if uimm != 0 {
                    self.csr.read_clear(csr, uimm as u64).map_err(|_| {
                        self.fault_addr = 0;
                        ExecError::Trap(2)
                    })?;
                }
                self.regs.set(rd, old);
                Ok(nx)
            }
            Insn::Ecall => {
                // U=8, S=9, H=10, M=11.
                self.fault_addr = 0;
                self.take_trap(8 + self.csr.mode() as u64);
                Ok(self.regs.pc)
            }
            Insn::Ebreak => {
                self.fault_addr = 0;
                self.take_trap(3);
                Ok(self.regs.pc)
            }
            Insn::Mret => {
                self.mret();
                Ok(self.regs.pc)
            }
            Insn::Sret => {
                self.sret();
                Ok(self.regs.pc)
            }
            Insn::Wfi => Ok(nx),
            Insn::CboInval { rs1 }
            | Insn::CboClean { rs1 }
            | Insn::CboFlush { rs1 }
            | Insn::CboZero { rs1 } => {
                // The native bring-up model has no data cache, so these are
                // architecturally no-ops; the address must still translate.
                let vaddr = self.regs.get(rs1);
                self.translate(mem, vaddr, 5)?;
                Ok(nx)
            }

            // F/D (single- and double-precision floating-point)
            Insn::Flw { .. }
            | Insn::Fld { .. }
            | Insn::Fsw { .. }
            | Insn::Fsd { .. }
            | Insn::FmaddS { .. }
            | Insn::FmsubS { .. }
            | Insn::FnmsubS { .. }
            | Insn::FnmaddS { .. }
            | Insn::FmaddD { .. }
            | Insn::FmsubD { .. }
            | Insn::FnmsubD { .. }
            | Insn::FnmaddD { .. }
            | Insn::FaddS { .. }
            | Insn::FsubS { .. }
            | Insn::FmulS { .. }
            | Insn::FdivS { .. }
            | Insn::FsqrtS { .. }
            | Insn::FaddD { .. }
            | Insn::FsubD { .. }
            | Insn::FmulD { .. }
            | Insn::FdivD { .. }
            | Insn::FsqrtD { .. }
            | Insn::FsgnjS { .. }
            | Insn::FsgnjnS { .. }
            | Insn::FsgnjxS { .. }
            | Insn::FsgnjD { .. }
            | Insn::FsgnjnD { .. }
            | Insn::FsgnjxD { .. }
            | Insn::FminS { .. }
            | Insn::FmaxS { .. }
            | Insn::FminD { .. }
            | Insn::FmaxD { .. }
            | Insn::FcvtWS { .. }
            | Insn::FcvtWuS { .. }
            | Insn::FcvtLS { .. }
            | Insn::FcvtLuS { .. }
            | Insn::FcvtWD { .. }
            | Insn::FcvtWuD { .. }
            | Insn::FcvtLD { .. }
            | Insn::FcvtLuD { .. }
            | Insn::FmvXW { .. }
            | Insn::FmvXD { .. }
            | Insn::FeqS { .. }
            | Insn::FltS { .. }
            | Insn::FleS { .. }
            | Insn::FclassS { .. }
            | Insn::FeqD { .. }
            | Insn::FltD { .. }
            | Insn::FleD { .. }
            | Insn::FclassD { .. }
            | Insn::FcvtSW { .. }
            | Insn::FcvtSWu { .. }
            | Insn::FcvtSL { .. }
            | Insn::FcvtSLu { .. }
            | Insn::FcvtDW { .. }
            | Insn::FcvtDWu { .. }
            | Insn::FcvtDL { .. }
            | Insn::FcvtDLu { .. }
            | Insn::FcvtSD { .. }
            | Insn::FcvtDS { .. }
            | Insn::FmvWX { .. }
            | Insn::FmvDX { .. } => self.execute_fp(insn, nx, xlen, mem),

            // AI-island queue instructions are handled outside the integer
            // execution unit because they touch the shared `AiIsland` device.
            Insn::AiEnq { rd, rs1 } => self.execute_ai_enq(rd, rs1, mem, nx),
            Insn::AiPoll { rd, rs1 } => self.execute_ai_poll(rd, rs1, mem, nx),
            Insn::AiQfence => self.execute_ai_qfence(mem, nx),

            Insn::Illegal(w) => {
                self.fault_addr = w as u64;
                self.take_trap(2);
                Ok(self.regs.pc)
            }
        }
    }

    // F/D (single- and double-precision floating-point) helpers and execution.

    const FFLAG_NX: u64 = 1 << 0;
    const FFLAG_UF: u64 = 1 << 1;
    const FFLAG_OF: u64 = 1 << 2;
    const FFLAG_DZ: u64 = 1 << 3;
    const FFLAG_NV: u64 = 1 << 4;

    /// Canonical floating-point quiet-NaN bit patterns.
    const F32_CANONICAL_NAN: u32 = 0x7fc0_0000;
    const F64_CANONICAL_NAN: u64 = 0x7ff8_0000_0000_0000;

    fn fp_rm(&self, rm: u8) -> u8 {
        if rm == 0x7 {
            self.csr.frm as u8
        } else {
            rm
        }
    }

    fn f32_get(&self, i: u8) -> f32 {
        f32::from_bits(self.fregs.get_s(i))
    }

    fn f32_set_raw(&mut self, i: u8, bits: u32) {
        self.fregs.set_s(i, bits);
    }

    /// Store an f32 arithmetic/conversion result (raw bits + flags), canonicalizing a produced NaN.
    fn f32_set_arith_bits(&mut self, i: u8, res: FpResult<u32>) {
        let bits = if f32::from_bits(res.value).is_nan() {
            Self::F32_CANONICAL_NAN
        } else {
            res.value
        };
        self.fregs.set_s(i, bits);
        self.csr.fflags |= res.flags & 0x1f;
    }

    fn set_fflag(&mut self, flag: u64) {
        self.csr.fflags |= flag & 0x1f;
    }

    fn sext32(v: u32) -> u64 {
        (v as i32) as i64 as u64
    }

    fn f32_minmax(a: f32, b: f32, max: bool) -> (f32, bool) {
        let a_snan = a.is_nan() && Self::f32_is_snan(a.to_bits());
        let b_snan = b.is_nan() && Self::f32_is_snan(b.to_bits());
        let nv = a_snan || b_snan;
        let r = if a.is_nan() && b.is_nan() {
            f32::from_bits(Self::F32_CANONICAL_NAN)
        } else if a.is_nan() {
            b
        } else if b.is_nan() {
            a
        } else if a == 0.0 && b == 0.0 {
            if max {
                if a.is_sign_positive() {
                    a
                } else {
                    b
                }
            } else if a.is_sign_negative() {
                a
            } else {
                b
            }
        } else if max {
            if a > b {
                a
            } else {
                b
            }
        } else if a < b {
            a
        } else {
            b
        };
        (r, nv)
    }

    fn fclass_s(v: f32) -> u64 {
        let bits = v.to_bits();
        let sign = bits & 0x8000_0000;
        let exp = (bits >> 23) & 0xff;
        let frac = bits & 0x007f_ffff;
        if exp == 0xff {
            if frac == 0 {
                if sign != 0 {
                    1 << 0 // -inf
                } else {
                    1 << 7 // +inf
                }
            } else if (frac & 0x0040_0000) != 0 {
                1 << 9 // quiet NaN
            } else {
                1 << 8 // signaling NaN
            }
        } else if exp == 0 {
            if frac == 0 {
                if sign != 0 {
                    1 << 3 // -0
                } else {
                    1 << 4 // +0
                }
            } else if sign != 0 {
                1 << 2 // negative subnormal
            } else {
                1 << 5 // positive subnormal
            }
        } else if sign != 0 {
            1 << 1 // negative normal
        } else {
            1 << 6 // positive normal
        }
    }

    // D (double-precision floating-point) helpers.

    fn f64_get(&self, i: u8) -> f64 {
        f64::from_bits(self.fregs.get_d(i))
    }

    fn f64_set_raw(&mut self, i: u8, bits: u64) {
        self.fregs.set_d(i, bits);
    }

    /// Store an f64 arithmetic/conversion result (raw bits + flags), canonicalizing a produced NaN.
    fn f64_set_arith_bits(&mut self, i: u8, res: FpResult<u64>) {
        let bits = if f64::from_bits(res.value).is_nan() {
            Self::F64_CANONICAL_NAN
        } else {
            res.value
        };
        self.fregs.set_d(i, bits);
        self.csr.fflags |= res.flags & 0x1f;
    }

    fn round_ties_even_f64(v: f64) -> f64 {
        let r = v.round();
        if (r - v).abs() == 0.5 {
            let r_int = r as i64;
            if r_int % 2 != 0 {
                if v > 0.0 {
                    r - 1.0
                } else {
                    r + 1.0
                }
            } else {
                r
            }
        } else {
            r
        }
    }

    fn f64_minmax(a: f64, b: f64, max: bool) -> (f64, bool) {
        let a_snan = a.is_nan() && Self::f64_is_snan(a.to_bits());
        let b_snan = b.is_nan() && Self::f64_is_snan(b.to_bits());
        let nv = a_snan || b_snan;
        let r = if a.is_nan() && b.is_nan() {
            f64::from_bits(Self::F64_CANONICAL_NAN)
        } else if a.is_nan() {
            b
        } else if b.is_nan() {
            a
        } else if a == 0.0 && b == 0.0 {
            if max {
                if a.is_sign_positive() {
                    a
                } else {
                    b
                }
            } else if a.is_sign_negative() {
                a
            } else {
                b
            }
        } else if max {
            if a > b {
                a
            } else {
                b
            }
        } else if a < b {
            a
        } else {
            b
        };
        (r, nv)
    }

    fn fclass_d(v: f64) -> u64 {
        let bits = v.to_bits();
        let sign = bits & 0x8000_0000_0000_0000;
        let exp = (bits >> 52) & 0x7ff;
        let frac = bits & 0x000f_ffff_ffff_ffff;
        if exp == 0x7ff {
            if frac == 0 {
                if sign != 0 {
                    1 << 0 // -inf
                } else {
                    1 << 7 // +inf
                }
            } else if (frac & 0x0008_0000_0000_0000) != 0 {
                1 << 9 // quiet NaN
            } else {
                1 << 8 // signaling NaN
            }
        } else if exp == 0 {
            if frac == 0 {
                if sign != 0 {
                    1 << 3 // -0
                } else {
                    1 << 4 // +0
                }
            } else if sign != 0 {
                1 << 2 // negative subnormal
            } else {
                1 << 5 // positive subnormal
            }
        } else if sign != 0 {
            1 << 1 // negative normal
        } else {
            1 << 6 // positive normal
        }
    }

    // FP helpers for conversions, canonicalisation and rounding-mode handling.

    /// True if the raw f32 bits are a signaling NaN.
    fn f32_is_snan(bits: u32) -> bool {
        (bits & 0x7f80_0000) == 0x7f80_0000 && bits != 0x7f80_0000 && (bits & 0x0040_0000) == 0
    }

    /// True if the raw f64 bits are a signaling NaN.
    fn f64_is_snan(bits: u64) -> bool {
        (bits & 0x7ff0_0000_0000_0000) == 0x7ff0_0000_0000_0000
            && bits != 0x7ff0_0000_0000_0000
            && (bits & 0x0008_0000_0000_0000) == 0
    }

    /// The next larger f32 (toward +inf) — `f32::next_up` is only stable in 1.86+.
    fn f32_next_up(v: f32) -> f32 {
        let bits = v.to_bits();
        if v.is_nan() || bits == f32::NEG_INFINITY.to_bits() {
            return v;
        }
        let abs = bits & 0x7fff_ffff;
        let next = if abs == 0 {
            0x0000_0001 // smallest positive subnormal
        } else if bits == abs {
            bits + 1
        } else {
            bits - 1
        };
        f32::from_bits(next)
    }

    /// The next smaller f32 (toward -inf).
    fn f32_next_down(v: f32) -> f32 {
        let bits = v.to_bits();
        if v.is_nan() || bits == f32::INFINITY.to_bits() {
            return v;
        }
        let abs = bits & 0x7fff_ffff;
        let next = if abs == 0 {
            0x8000_0001 // smallest negative subnormal
        } else if bits == abs {
            bits - 1
        } else {
            bits + 1
        };
        f32::from_bits(next)
    }

    /// The next larger f64 (toward +inf).
    fn f64_next_up(v: f64) -> f64 {
        let bits = v.to_bits();
        if v.is_nan() || bits == f64::NEG_INFINITY.to_bits() {
            return v;
        }
        let abs = bits & 0x7fff_ffff_ffff_ffff;
        let next = if abs == 0 {
            0x0000_0000_0000_0001
        } else if bits == abs {
            bits + 1
        } else {
            bits - 1
        };
        f64::from_bits(next)
    }

    /// The next smaller f64 (toward -inf).
    fn f64_next_down(v: f64) -> f64 {
        let bits = v.to_bits();
        if v.is_nan() || bits == f64::INFINITY.to_bits() {
            return v;
        }
        let abs = bits & 0x7fff_ffff_ffff_ffff;
        let next = if abs == 0 {
            0x8000_0000_0000_0001
        } else if bits == abs {
            bits - 1
        } else {
            bits + 1
        };
        f64::from_bits(next)
    }

    /// Convert an f64 value to f32 bits with the requested rounding mode and exception flags.
    ///
    /// If `allow_infinite` is true, an `v` that is already ±inf is treated as a source value and
    /// does not raise OF.  If false, a produced ±inf means overflow and OF+NX is raised.
    fn round_f64_to_f32(v: f64, rm: u8, allow_infinite: bool) -> FpResult<u32> {
        if v.is_nan() {
            let bits = v.to_bits();
            let nv = if Self::f64_is_snan(bits) {
                Self::FFLAG_NV
            } else {
                0
            };
            return FpResult {
                value: Self::F32_CANONICAL_NAN,
                flags: nv,
            };
        }
        if v.is_infinite() {
            let inf = if v.is_sign_negative() {
                f32::NEG_INFINITY
            } else {
                f32::INFINITY
            };
            return FpResult {
                value: inf.to_bits(),
                flags: if allow_infinite {
                    0
                } else {
                    Self::FFLAG_OF | Self::FFLAG_NX
                },
            };
        }

        let sign_neg = v.is_sign_negative();
        let max_f = f32::MAX as f64;

        if v.abs() > max_f {
            let r = v as f32;
            let inf_bits = if sign_neg {
                f32::NEG_INFINITY.to_bits()
            } else {
                f32::INFINITY.to_bits()
            };
            let max_bits = if sign_neg {
                (-f32::MAX).to_bits()
            } else {
                f32::MAX.to_bits()
            };
            let bits = match rm {
                0x0 | 0x4 => r.to_bits(), // RNE / RMM: nearest (Rust cast is RNE; ties match RMM here)
                0x1 | 0x2 if !sign_neg => max_bits, // RTZ / RDN for positive
                0x1 | 0x3 if sign_neg => max_bits, // RTZ / RUP for negative
                0x3 if !sign_neg => inf_bits, // RUP for positive
                0x2 if sign_neg => inf_bits, // RDN for negative
                _ => r.to_bits(),
            };
            return FpResult {
                value: bits,
                flags: Self::FFLAG_OF | Self::FFLAG_NX,
            };
        }

        let r = v as f32;
        if f64::from(r) == v {
            return FpResult {
                value: r.to_bits(),
                flags: 0,
            };
        }

        let lower = if f64::from(r) < v {
            r
        } else {
            Self::f32_next_down(r)
        };
        let upper = if f64::from(r) < v {
            Self::f32_next_up(r)
        } else {
            r
        };

        let result = match rm {
            0x0 => r, // RNE: Rust cast already gives nearest-even
            0x1 => {
                // RTZ: toward zero (smaller magnitude)
                if v >= 0.0 {
                    lower
                } else {
                    upper
                }
            }
            0x2 => lower,                          // RDN: toward -inf
            0x3 => upper,                          // RUP: toward +inf
            0x4 => Self::f32_rmm(v, lower, upper), // RMM
            _ => r,                                // reserved
        };

        let mut flags = 0;
        let result_f = f64::from(result);
        if result_f != v {
            flags |= Self::FFLAG_NX;
        }
        if (result == 0.0 && v != 0.0) || result.is_subnormal() {
            flags |= Self::FFLAG_UF;
        }
        FpResult {
            value: result.to_bits(),
            flags,
        }
    }

    /// RMM (round to nearest, ties away from zero) between two bracketing f32 values.
    fn f32_rmm(v: f64, lower: f32, upper: f32) -> f32 {
        let lower_f = f64::from(lower);
        let upper_f = f64::from(upper);
        let d_low = v - lower_f;
        let d_high = upper_f - v;
        if d_low < d_high {
            lower
        } else if d_high < d_low {
            upper
        } else {
            // Tie: away from zero.
            if v > 0.0 {
                upper
            } else {
                lower
            }
        }
    }

    /// Convert a signed/unsigned integer to f32 bits, honouring the rounding mode.
    fn int_to_f32(source: i128, rm: u8) -> FpResult<u32> {
        if source == 0 {
            return FpResult {
                value: 0x0000_0000,
                flags: 0,
            };
        }
        let v = source as f64;
        // For |source| > f64::MAX, the `as f64` saturates to ±inf and we must
        // still produce an overflowed f32. Saturated to inf also raises OF/NX.
        if v.is_infinite() {
            let sign_neg = source < 0;
            let bits = match rm {
                0x1 | 0x2 if !sign_neg => f32::MAX.to_bits(),
                0x1 | 0x3 if sign_neg => (-f32::MAX).to_bits(),
                0x3 if !sign_neg => f32::INFINITY.to_bits(),
                0x2 if sign_neg => f32::NEG_INFINITY.to_bits(),
                _ if !sign_neg => f32::INFINITY.to_bits(),
                _ => f32::NEG_INFINITY.to_bits(),
            };
            return FpResult {
                value: bits,
                flags: Self::FFLAG_OF | Self::FFLAG_NX,
            };
        }
        let mut r = Self::round_f64_to_f32(v, rm, false);
        if r.flags & Self::FFLAG_OF != 0 {
            return r;
        }
        // If the rounded f32 value does not recover the original integer, the
        // conversion was inexact (already marked NX by round_f64_to_f32).  If it
        // does recover it but source > f32::MAX, we would have overflowed above.
        let back = f64::from(f32::from_bits(r.value)) as i128;
        if back != source && r.flags == 0 {
            r.flags |= Self::FFLAG_NX;
        }
        r
    }

    /// Convert a signed/unsigned integer to f64 bits, honouring the rounding mode.
    fn int_to_f64(source: i128, rm: u8) -> FpResult<u64> {
        if source == 0 {
            return FpResult {
                value: 0x0000_0000_0000_0000,
                flags: 0,
            };
        }
        // f64 can represent all 64-bit signed/unsigned integers exactly when they
        // are within its precision (up to 2^53).  Beyond that we must round.
        let v = source as f64;
        if v.is_infinite() {
            // source did not fit in f64 at all; rounded to ±inf.
            let sign_neg = source < 0;
            let bits = match rm {
                0x1 | 0x2 if !sign_neg => f64::MAX.to_bits(),
                0x1 | 0x3 if sign_neg => (-f64::MAX).to_bits(),
                0x3 if !sign_neg => f64::INFINITY.to_bits(),
                0x2 if sign_neg => f64::NEG_INFINITY.to_bits(),
                _ if !sign_neg => f64::INFINITY.to_bits(),
                _ => f64::NEG_INFINITY.to_bits(),
            };
            return FpResult {
                value: bits,
                flags: Self::FFLAG_OF | Self::FFLAG_NX,
            };
        }
        let result = Self::f64_round_directed(v, v, rm);
        let mut flags = 0;
        if (result as i128) != source {
            flags |= Self::FFLAG_NX;
            // Detect overflow: the rounded f64 is too large for the original integer
            // magnitude and the conversion is inexact.  Mark OF too.
            if source.unsigned_abs() > f64::MAX as u128 {
                flags |= Self::FFLAG_OF;
            }
        }
        FpResult {
            value: result.to_bits(),
            flags,
        }
    }

    /// Error-free transformation of the sum of two f64 values.
    /// Returns `(s, e)` such that `a + b = s + e` exactly for finite `s`.
    fn two_sum(a: f64, b: f64) -> (f64, f64) {
        let s = a + b;
        let v = s - b;
        let w = s - v;
        let da = a - v;
        let db = b - w;
        (s, da + db)
    }

    /// Split a f64 value into a high and low part for exact multiplication.
    fn split(a: f64) -> (f64, f64) {
        let c = (1u64 << 27) as f64 + 1.0;
        let t = c * a;
        let x = t - a;
        let hi = t - x;
        let lo = a - hi;
        (hi, lo)
    }

    /// Error-free transformation of the product of two f64 values.
    /// Returns `(p, e)` such that `a * b = p + e` exactly for non-overflowing products
    /// in the normal range.  Large operands or subnormal results may produce a non-exact
    /// `e`; callers must guard against those cases.
    fn two_prod(a: f64, b: f64) -> (f64, f64) {
        let p = a * b;
        let (a_hi, a_lo) = Self::split(a);
        let (b_hi, b_lo) = Self::split(b);
        let err = ((a_hi * b_hi - p) + a_hi * b_lo + a_lo * b_hi) + a_lo * b_lo;
        (p, err)
    }

    /// Round an exact value represented as `hi + lo` (two f64s) to a single f64 using `rm`.
    /// `hi` is the rounded-to-nearest result and `lo` is the exact error (|lo| <= 0.5 ulp).
    fn f64_round_two(hi: f64, lo: f64, rm: u8) -> FpResult<u64> {
        if lo == 0.0 || (rm == 0x0 || rm > 0x4) {
            // RNE, or the exact result is exactly representable as hi.
            return FpResult {
                value: hi.to_bits(),
                flags: if lo == 0.0 { 0 } else { Self::FFLAG_NX },
            };
        }

        let (lower, upper) = if lo > 0.0 {
            (hi, Self::f64_next_up(hi))
        } else {
            (Self::f64_next_down(hi), hi)
        };
        let ulp = upper - lower; // always positive
        let tie = 2.0 * lo.abs() == ulp;

        let result = match rm {
            0x1 => {
                // RTZ: toward zero -- the candidate with smaller magnitude.
                if hi.is_sign_positive() {
                    lower
                } else {
                    upper
                }
            }
            0x2 => lower, // RDN: toward -inf -- the smaller value.
            0x3 => upper, // RUP: toward +inf -- the larger value.
            0x4 => {
                // RMM: round to nearest, ties away from zero.
                if tie {
                    if hi.is_sign_positive() {
                        upper
                    } else {
                        lower
                    }
                } else {
                    hi
                }
            }
            _ => hi,
        };

        let mut flags = Self::FFLAG_NX;
        if result == 0.0 || result.is_subnormal() {
            flags |= Self::FFLAG_UF;
        }
        FpResult {
            value: result.to_bits(),
            flags,
        }
    }

    /// Apply a directed rounding mode to an already rounded-to-nearest f64 value.
    /// Used for f64 conversions where the source is an exact real (or an f64).
    fn f64_round_directed(v: f64, r: f64, rm: u8) -> f64 {
        if r == v || rm == 0x0 || rm > 0x4 {
            return r;
        }
        let lower = if r < v { r } else { Self::f64_next_down(r) };
        let upper = if r < v { Self::f64_next_up(r) } else { r };
        match rm {
            0x1 => {
                // RTZ: toward zero
                if v >= 0.0 {
                    lower
                } else {
                    upper
                }
            }
            0x2 => lower,
            0x3 => upper,
            0x4 => Self::f64_rmm(v, lower, upper),
            _ => r,
        }
    }

    fn f64_rmm(v: f64, lower: f64, upper: f64) -> f64 {
        let d_low = v - lower;
        let d_high = upper - v;
        let tie = d_low == d_high;
        if d_low < d_high || (tie && v < 0.0) {
            lower
        } else {
            upper
        }
    }

    /// Convert an f32 value to a signed/unsigned integer of `width` bits.
    fn f32_to_int(v: f64, rm: u8, width: u8, unsign: bool) -> FpResult<u64> {
        if v.is_nan() {
            let limit_bits = if unsign { width } else { width - 1 };
            return FpResult {
                value: (1u128 << limit_bits).saturating_sub(1) as u64,
                flags: Self::FFLAG_NV,
            };
        }
        if v.is_infinite() {
            let (max, min) = Self::int_limits(width, unsign);
            let value = if v.is_sign_negative() {
                if unsign {
                    0
                } else {
                    min
                }
            } else {
                max
            };
            return FpResult {
                value: value as u64,
                flags: Self::FFLAG_NV,
            };
        }

        let rounded = Self::f64_round_to_int(v, rm);
        let (max, min) = Self::int_limits(width, unsign);
        if rounded > max as f64 {
            FpResult {
                value: max as u64,
                flags: Self::FFLAG_NV,
            }
        } else if rounded < min as f64 {
            FpResult {
                value: min as u64,
                flags: Self::FFLAG_NV,
            }
        } else {
            let r = rounded as i128;
            let value = if r < 0 && unsign { 0 } else { r as u64 };
            let mut flags = 0;
            if rounded != v {
                flags |= Self::FFLAG_NX;
            }
            FpResult { value, flags }
        }
    }

    /// Convert an f64 value to a signed/unsigned integer of `width` bits.
    fn f64_to_int(v: f64, rm: u8, width: u8, unsign: bool) -> FpResult<u64> {
        if v.is_nan() {
            let limit_bits = if unsign { width } else { width - 1 };
            return FpResult {
                value: (1u128 << limit_bits).saturating_sub(1) as u64,
                flags: Self::FFLAG_NV,
            };
        }
        if v.is_infinite() {
            let (max, min) = Self::int_limits(width, unsign);
            let value = if v.is_sign_negative() {
                if unsign {
                    0
                } else {
                    min
                }
            } else {
                max
            };
            return FpResult {
                value: value as u64,
                flags: Self::FFLAG_NV,
            };
        }

        let rounded = Self::f64_round_to_int(v, rm);
        let (max, min) = Self::int_limits(width, unsign);
        if rounded > max as f64 {
            FpResult {
                value: max as u64,
                flags: Self::FFLAG_NV,
            }
        } else if rounded < min as f64 {
            FpResult {
                value: min as u64,
                flags: Self::FFLAG_NV,
            }
        } else {
            let r = rounded as i128;
            let value = if r < 0 && unsign { 0 } else { r as u64 };
            let mut flags = 0;
            if rounded != v {
                flags |= Self::FFLAG_NX;
            }
            FpResult { value, flags }
        }
    }

    /// Produce the correctly rounded overflow result for f64 arithmetic.
    fn f64_overflow(sign_neg: bool, rm: u8) -> FpResult<u64> {
        let to_inf = match rm {
            0x0 | 0x4 => true, // RNE / RMM -> infinity
            0x1 => false,      // RTZ -> max finite
            0x2 => sign_neg,   // RDN -> infinity if negative, max finite if positive
            0x3 => !sign_neg,  // RUP -> infinity if positive, max finite if negative
            _ => true,
        };
        let value = if to_inf {
            if sign_neg {
                f64::NEG_INFINITY
            } else {
                f64::INFINITY
            }
        } else if sign_neg {
            -f64::MAX
        } else {
            f64::MAX
        };
        FpResult {
            value: value.to_bits(),
            flags: Self::FFLAG_OF | Self::FFLAG_NX,
        }
    }

    /// Round a finite f64 to an integer using the requested rounding mode.
    fn f64_round_to_int(v: f64, rm: u8) -> f64 {
        match rm {
            0x0 => Self::round_ties_even_f64(v), // RNE
            0x1 => v.trunc(),                    // RTZ
            0x2 => v.floor(),                    // RDN
            0x3 => v.ceil(),                     // RUP
            0x4 => v.round(),                    // RMM
            _ => v.trunc(),                      // reserved
        }
    }

    /// Signed/unsigned limits for an integer of `width` bits.
    fn int_limits(width: u8, unsign: bool) -> (i128, i128) {
        let max = (1i128 << (if unsign { width } else { width - 1 })) - 1;
        let min = if unsign { 0 } else { -(1i128 << (width - 1)) };
        (max, min)
    }

    /// Extract the integer value represented in an X register, with the requested width/sign.
    fn int_source(v: u64, xlen: u8, width: u8, unsign: bool) -> i128 {
        if width == 32 {
            if unsign {
                (v as u32) as i128
            } else {
                (v as u32) as i32 as i128
            }
        } else if unsign {
            v as i128
        } else if xlen == 32 {
            (v as i32) as i128
        } else {
            (v as i64) as i128
        }
    }

    /// Widen f32 to f64. Widening is exact except for NaN canonicalisation.
    fn round_f32_to_f64(v: f32) -> FpResult<u64> {
        if v.is_nan() {
            let nv = if Self::f32_is_snan(v.to_bits()) {
                Self::FFLAG_NV
            } else {
                0
            };
            return FpResult {
                value: Self::F64_CANONICAL_NAN,
                flags: nv,
            };
        }
        FpResult {
            value: f64::from(v).to_bits(),
            flags: 0,
        }
    }

    // FP arithmetic helpers for f32 (computed in f64 and rounded to f32) and f64 (host).

    /// Canonicalise a NaN-producing f32 arithmetic/conversion and record NV if any source was
    /// signaling.  `a` and `b` are the raw source f32 values (or 0 for unary ops).
    fn f32_nan_result(a: f32, b: f32) -> FpResult<u32> {
        let a_snan = a.is_nan() && Self::f32_is_snan(a.to_bits());
        let b_snan = b.is_nan() && b != 0.0 && Self::f32_is_snan(b.to_bits());
        FpResult {
            value: Self::F32_CANONICAL_NAN,
            flags: if a_snan || b_snan { Self::FFLAG_NV } else { 0 },
        }
    }

    /// Canonicalise a NaN-producing f64 arithmetic/conversion and record NV if any source was
    /// signaling.
    fn f64_nan_result(a: f64, b: f64) -> FpResult<u64> {
        let a_snan = a.is_nan() && Self::f64_is_snan(a.to_bits());
        let b_snan = b.is_nan() && b != 0.0 && Self::f64_is_snan(b.to_bits());
        FpResult {
            value: Self::F64_CANONICAL_NAN,
            flags: if a_snan || b_snan { Self::FFLAG_NV } else { 0 },
        }
    }

    /// Compute `a + b` for f32, rounding to `rm`.
    fn f32_add(a: f32, b: f32, rm: u8) -> FpResult<u32> {
        if a.is_nan() || b.is_nan() {
            return Self::f32_nan_result(a, b);
        }
        if a.is_infinite() && b.is_infinite() && (a.is_sign_negative() != b.is_sign_negative()) {
            return FpResult {
                value: Self::F32_CANONICAL_NAN,
                flags: Self::FFLAG_NV,
            };
        }
        let ai = f64::from(a);
        let bi = f64::from(b);
        let exact = ai + bi;
        if exact.is_nan() {
            return FpResult {
                value: Self::F32_CANONICAL_NAN,
                flags: Self::FFLAG_NV,
            };
        }
        Self::round_f64_to_f32(exact, rm, a.is_infinite() || b.is_infinite())
    }

    /// Compute `a - b` for f32, rounding to `rm`.
    fn f32_sub(a: f32, b: f32, rm: u8) -> FpResult<u32> {
        if a.is_nan() || b.is_nan() {
            return Self::f32_nan_result(a, b);
        }
        if a.is_infinite() && b.is_infinite() && (a.is_sign_negative() == b.is_sign_negative()) {
            return FpResult {
                value: Self::F32_CANONICAL_NAN,
                flags: Self::FFLAG_NV,
            };
        }
        let ai = f64::from(a);
        let bi = f64::from(b);
        let exact = ai - bi;
        if exact.is_nan() {
            return FpResult {
                value: Self::F32_CANONICAL_NAN,
                flags: Self::FFLAG_NV,
            };
        }
        Self::round_f64_to_f32(exact, rm, a.is_infinite() || b.is_infinite())
    }

    /// Compute `a * b` for f32, rounding to `rm`.
    fn f32_mul(a: f32, b: f32, rm: u8) -> FpResult<u32> {
        if a.is_nan() || b.is_nan() {
            return Self::f32_nan_result(a, b);
        }
        if (a.is_infinite() && b == 0.0) || (b.is_infinite() && a == 0.0) {
            return FpResult {
                value: Self::F32_CANONICAL_NAN,
                flags: Self::FFLAG_NV,
            };
        }
        let ai = f64::from(a);
        let bi = f64::from(b);
        let exact = ai * bi;
        if exact.is_nan() {
            return FpResult {
                value: Self::F32_CANONICAL_NAN,
                flags: Self::FFLAG_NV,
            };
        }
        Self::round_f64_to_f32(exact, rm, a.is_infinite() || b.is_infinite())
    }

    /// Compute `a / b` for f32, rounding to `rm`.
    fn f32_div(a: f32, b: f32, rm: u8) -> FpResult<u32> {
        if a.is_nan() || b.is_nan() {
            return Self::f32_nan_result(a, b);
        }
        if a == 0.0 && b == 0.0 {
            return FpResult {
                value: Self::F32_CANONICAL_NAN,
                flags: Self::FFLAG_NV,
            };
        }
        if a.is_infinite() && b.is_infinite() {
            return FpResult {
                value: Self::F32_CANONICAL_NAN,
                flags: Self::FFLAG_NV,
            };
        }
        let mut flags = 0;
        if b == 0.0 {
            flags |= Self::FFLAG_DZ;
        }
        let ai = f64::from(a);
        let bi = f64::from(b);
        let exact = ai / bi;
        if exact.is_nan() {
            return FpResult {
                value: Self::F32_CANONICAL_NAN,
                flags: Self::FFLAG_NV,
            };
        }
        let mut res = Self::round_f64_to_f32(exact, rm, a.is_infinite() || b.is_infinite());
        res.flags |= flags;
        res
    }

    /// Compute `sqrt(a)` for f32, rounding to `rm`.
    fn f32_sqrt(a: f32, rm: u8) -> FpResult<u32> {
        if a.is_nan() {
            return Self::f32_nan_result(a, 0.0);
        }
        if a < 0.0 && a != -0.0 {
            return FpResult {
                value: Self::F32_CANONICAL_NAN,
                flags: Self::FFLAG_NV,
            };
        }
        if a.is_infinite() && a.is_sign_negative() {
            return FpResult {
                value: Self::F32_CANONICAL_NAN,
                flags: Self::FFLAG_NV,
            };
        }
        let exact = f64::from(a).sqrt();
        if exact.is_nan() {
            return FpResult {
                value: Self::F32_CANONICAL_NAN,
                flags: Self::FFLAG_NV,
            };
        }
        Self::round_f64_to_f32(exact, rm, a.is_infinite())
    }

    /// Compute a fused multiply-add variant for f32: `prod = a*b`, then `prod +/- c`.
    ///
    /// The full multiply-add is performed in f64 with one `mul_add` rounding, then
    /// rounded to f32, so the final f32 rounding is the only rounding that matters.
    /// `neg_p` negates the product; `neg_s` negates the summand.
    fn f32_fma(a: f32, b: f32, c: f32, rm: u8, neg_p: bool, neg_s: bool) -> FpResult<u32> {
        if a.is_nan() || b.is_nan() || c.is_nan() {
            let mut r = Self::f32_nan_result(a, b);
            if c.is_nan() && Self::f32_is_snan(c.to_bits()) {
                r.flags |= Self::FFLAG_NV;
            }
            return r;
        }
        if (a.is_infinite() && b == 0.0) || (b.is_infinite() && a == 0.0) {
            return FpResult {
                value: Self::F32_CANONICAL_NAN,
                flags: Self::FFLAG_NV,
            };
        }
        let mut ai = f64::from(a);
        let bi = f64::from(b);
        let mut ci = f64::from(c);
        if neg_p {
            ai = -ai;
        }
        if neg_s {
            ci = -ci;
        }
        let exact = ai.mul_add(bi, ci);
        if exact.is_nan() {
            // NaN here means inf + (-inf) or vice versa, which is invalid.
            return FpResult {
                value: Self::F32_CANONICAL_NAN,
                flags: Self::FFLAG_NV,
            };
        }
        let input_inf = a.is_infinite() || b.is_infinite() || c.is_infinite();
        Self::round_f64_to_f32(exact, rm, input_inf)
    }

    /// Compute `a + b` for f64, honouring the dynamic rounding mode and setting NX/OF/UF.
    fn f64_add(a: f64, b: f64, rm: u8) -> FpResult<u64> {
        if a.is_nan() || b.is_nan() {
            return Self::f64_nan_result(a, b);
        }
        if a.is_infinite() && b.is_infinite() && (a.is_sign_negative() != b.is_sign_negative()) {
            return FpResult {
                value: Self::F64_CANONICAL_NAN,
                flags: Self::FFLAG_NV,
            };
        }
        if a.is_infinite() || b.is_infinite() {
            let r = a + b;
            return FpResult {
                value: r.to_bits(),
                flags: 0,
            };
        }

        let s = a + b;
        if s.is_infinite() {
            return Self::f64_overflow(s.is_sign_negative(), rm);
        }

        let (hi, lo) = Self::two_sum(a, b);
        if lo.is_nan() {
            // two_sum is only expected to fail when s overflowed, which is handled above.
            return Self::f64_arith_finish(s, false, false);
        }
        Self::f64_round_two(hi, lo, rm)
    }

    /// Compute `a - b` for f64, honouring the dynamic rounding mode and setting NX/OF/UF.
    fn f64_sub(a: f64, b: f64, rm: u8) -> FpResult<u64> {
        if a.is_nan() || b.is_nan() {
            return Self::f64_nan_result(a, b);
        }
        if a.is_infinite() && b.is_infinite() && (a.is_sign_negative() == b.is_sign_negative()) {
            return FpResult {
                value: Self::F64_CANONICAL_NAN,
                flags: Self::FFLAG_NV,
            };
        }
        if a.is_infinite() || b.is_infinite() {
            let r = a - b;
            return FpResult {
                value: r.to_bits(),
                flags: 0,
            };
        }

        let s = a - b;
        if s.is_infinite() {
            return Self::f64_overflow(s.is_sign_negative(), rm);
        }

        let (hi, lo) = Self::two_sum(a, -b);
        if lo.is_nan() {
            return Self::f64_arith_finish(s, false, false);
        }
        Self::f64_round_two(hi, lo, rm)
    }

    /// Compute `a * b` for f64, honouring the dynamic rounding mode and setting NX/OF/UF.
    fn f64_mul(a: f64, b: f64, rm: u8) -> FpResult<u64> {
        if a.is_nan() || b.is_nan() {
            return Self::f64_nan_result(a, b);
        }
        if (a.is_infinite() && b == 0.0) || (b.is_infinite() && a == 0.0) {
            return FpResult {
                value: Self::F64_CANONICAL_NAN,
                flags: Self::FFLAG_NV,
            };
        }
        if a.is_infinite() || b.is_infinite() {
            let r = a * b;
            return FpResult {
                value: r.to_bits(),
                flags: 0,
            };
        }

        let p = a * b;
        if p.is_infinite() {
            return Self::f64_overflow(p.is_sign_negative(), rm);
        }
        if p.is_subnormal() || p == 0.0 {
            // two_prod is not reliable in the subnormal/underflow range; fall back to the
            // rounded product and flag underflow when the result is tiny and non-zero.
            let mut flags = 0;
            if p.is_subnormal() && (a != 0.0 && b != 0.0) {
                flags |= Self::FFLAG_UF;
            }
            if p == 0.0 && (a != 0.0 && b != 0.0) {
                flags |= Self::FFLAG_UF | Self::FFLAG_NX;
            }
            return FpResult {
                value: p.to_bits(),
                flags,
            };
        }

        let (hi, lo) = Self::two_prod(a, b);
        if lo.is_nan() {
            // split overflow or other split failure: use the rounded product.
            return Self::f64_arith_finish(p, false, false);
        }
        Self::f64_round_two(hi, lo, rm)
    }

    /// Compute `a / b` for f64, with improved flag detection.
    fn f64_div(a: f64, b: f64, _rm: u8) -> FpResult<u64> {
        if a.is_nan() || b.is_nan() {
            return Self::f64_nan_result(a, b);
        }
        if a == 0.0 && b == 0.0 {
            return FpResult {
                value: Self::F64_CANONICAL_NAN,
                flags: Self::FFLAG_NV,
            };
        }
        if a.is_infinite() && b.is_infinite() {
            return FpResult {
                value: Self::F64_CANONICAL_NAN,
                flags: Self::FFLAG_NV,
            };
        }
        let r = a / b;
        Self::f64_arith_finish(r, b == 0.0, a.is_infinite() || b.is_infinite())
    }

    /// Compute `sqrt(a)` for f64, with improved flag detection.
    fn f64_sqrt(a: f64, _rm: u8) -> FpResult<u64> {
        if a.is_nan() {
            return Self::f64_nan_result(a, 0.0);
        }
        if a < 0.0 && a != -0.0 {
            return FpResult {
                value: Self::F64_CANONICAL_NAN,
                flags: Self::FFLAG_NV,
            };
        }
        if a.is_infinite() && a.is_sign_negative() {
            return FpResult {
                value: Self::F64_CANONICAL_NAN,
                flags: Self::FFLAG_NV,
            };
        }
        let r = a.sqrt();
        Self::f64_arith_finish(r, false, a.is_infinite())
    }

    /// Compute a fused multiply-add variant for f64.
    ///
    /// Uses the host `mul_add` intrinsic to perform one f64 rounding instead of
    /// two separate operations. Dynamic rounding modes are still not honored for
    /// f64 because the host f64 path has no wider accumulator.
    fn f64_fma(a: f64, b: f64, c: f64, _rm: u8, neg_p: bool, neg_s: bool) -> FpResult<u64> {
        if a.is_nan() || b.is_nan() || c.is_nan() {
            let mut r = Self::f64_nan_result(a, b);
            if c.is_nan() && Self::f64_is_snan(c.to_bits()) {
                r.flags |= Self::FFLAG_NV;
            }
            return r;
        }
        if (a.is_infinite() && b == 0.0) || (b.is_infinite() && a == 0.0) {
            return FpResult {
                value: Self::F64_CANONICAL_NAN,
                flags: Self::FFLAG_NV,
            };
        }
        let a = if neg_p { -a } else { a };
        let c = if neg_s { -c } else { c };
        let r = a.mul_add(b, c);
        if r.is_nan() {
            return FpResult {
                value: Self::F64_CANONICAL_NAN,
                flags: Self::FFLAG_NV,
            };
        }
        let input_inf = a.is_infinite() || b.is_infinite() || c.is_infinite();
        Self::f64_arith_finish(r, false, input_inf)
    }

    /// Finalise an f64 host arithmetic result: canonicalise NaN, set OF/DZ/NV where detectable.
    ///
    /// This does not attempt to set NX/UF because the host f64 path cannot recover the exact
    /// real result for double-precision operations without a wider accumulator.
    fn f64_arith_finish(r: f64, div_by_zero: bool, input_inf: bool) -> FpResult<u64> {
        if r.is_nan() {
            // Host produced NaN from an unhandled invalid combination; mark NV.
            return FpResult {
                value: Self::F64_CANONICAL_NAN,
                flags: Self::FFLAG_NV,
            };
        }
        let mut flags = 0;
        if div_by_zero {
            flags |= Self::FFLAG_DZ;
        }
        if r.is_infinite() && !input_inf {
            flags |= Self::FFLAG_OF | Self::FFLAG_NX;
        }
        FpResult {
            value: r.to_bits(),
            flags,
        }
    }

    fn execute_ai_enq(
        &mut self,
        rd: u8,
        rs1: u8,
        mem: &mut PhysMem,
        nx: u64,
    ) -> Result<u64, ExecError> {
        let desc_addr = self.regs.get(rs1);
        let hart = self.csr.hartid as u32;
        let event = self
            .ai_model
            .as_ref()
            .and_then(|m| crate::device::AiIsland::read_descriptor_event(mem, desc_addr, hart, m));
        if let Some(ai) = mem.ai_island_mut() {
            let hart = self.csr.hartid as u32;
            let ticket = ai.queue_enq_with_event(desc_addr, hart, event).unwrap_or(0);
            self.regs.set(rd, ticket);
            Ok(nx)
        } else {
            self.fault_addr = 0;
            self.take_trap(2);
            Ok(self.regs.pc)
        }
    }

    fn execute_ai_poll(
        &mut self,
        rd: u8,
        rs1: u8,
        mem: &mut PhysMem,
        nx: u64,
    ) -> Result<u64, ExecError> {
        let ticket = self.regs.get(rs1);
        if let Some(ai) = mem.ai_island_mut() {
            let (mut word, ptr_done) = ai.queue_poll_details(ticket);
            // The island writes the completion word to ptr_done only when the entry is done;
            // while pending the guest just sees the 0xffff_ffff sentinel.
            if ptr_done != 0
                && word != 0xffff_ffff
                && Self::write_ai_completion(mem, ptr_done, word).is_err()
            {
                if let Some(ai) = mem.ai_island_mut() {
                    word = ai.fail_queue_dma(ticket);
                }
            }
            self.regs.set(rd, word);
            Ok(nx)
        } else {
            self.fault_addr = 0;
            self.take_trap(2);
            Ok(self.regs.pc)
        }
    }

    fn execute_ai_qfence(&mut self, mem: &mut PhysMem, nx: u64) -> Result<u64, ExecError> {
        let pending = if let Some(ai) = mem.ai_island_mut() {
            let pending = ai.pending_queue_completions();
            ai.queue_qfence();
            pending
        } else {
            self.fault_addr = 0;
            self.take_trap(2);
            return Ok(self.regs.pc);
        };
        for (ticket, ptr) in pending {
            let word = mem
                .ai_island_mut()
                .map(|ai| ai.queue_poll_details(ticket).0);
            if let Some(word) = word {
                if Self::write_ai_completion(mem, ptr, word).is_err() {
                    if let Some(ai) = mem.ai_island_mut() {
                        ai.fail_queue_dma(ticket);
                    }
                }
            }
        }
        Ok(nx)
    }

    fn execute_fp(
        &mut self,
        insn: Insn,
        nx: u64,
        xlen: u8,
        mem: &mut PhysMem,
    ) -> Result<u64, ExecError> {
        match insn {
            Insn::Flw { rd, rs1, imm } => {
                let addr = self.regs.get(rs1).wrapping_add(imm as u64);
                let v = self.load_le::<4>(mem, addr)?;
                self.fregs.set_s(rd, v as u32);
                Ok(nx)
            }
            Insn::Fsw { rs1, rs2, imm } => {
                let addr = self.regs.get(rs1).wrapping_add(imm as u64);
                let v = self.fregs.get_s(rs2);
                self.store_le::<4>(mem, addr, v as u64)?;
                Ok(nx)
            }

            // Fused multiply-add
            Insn::FmaddS {
                rd,
                rs1,
                rs2,
                rs3,
                rm,
            } => {
                let a = self.f32_get(rs1);
                let b = self.f32_get(rs2);
                let c = self.f32_get(rs3);
                let res = Self::f32_fma(a, b, c, self.fp_rm(rm), false, false);
                self.f32_set_arith_bits(rd, res);
                Ok(nx)
            }
            Insn::FmsubS {
                rd,
                rs1,
                rs2,
                rs3,
                rm,
            } => {
                let a = self.f32_get(rs1);
                let b = self.f32_get(rs2);
                let c = self.f32_get(rs3);
                let res = Self::f32_fma(a, b, c, self.fp_rm(rm), false, true);
                self.f32_set_arith_bits(rd, res);
                Ok(nx)
            }
            Insn::FnmsubS {
                rd,
                rs1,
                rs2,
                rs3,
                rm,
            } => {
                let a = self.f32_get(rs1);
                let b = self.f32_get(rs2);
                let c = self.f32_get(rs3);
                let res = Self::f32_fma(a, b, c, self.fp_rm(rm), true, false);
                self.f32_set_arith_bits(rd, res);
                Ok(nx)
            }
            Insn::FnmaddS {
                rd,
                rs1,
                rs2,
                rs3,
                rm,
            } => {
                let a = self.f32_get(rs1);
                let b = self.f32_get(rs2);
                let c = self.f32_get(rs3);
                let res = Self::f32_fma(a, b, c, self.fp_rm(rm), true, true);
                self.f32_set_arith_bits(rd, res);
                Ok(nx)
            }

            // Basic arithmetic
            Insn::FaddS { rd, rs1, rs2, rm } => {
                let a = self.f32_get(rs1);
                let b = self.f32_get(rs2);
                let res = Self::f32_add(a, b, self.fp_rm(rm));
                self.f32_set_arith_bits(rd, res);
                Ok(nx)
            }
            Insn::FsubS { rd, rs1, rs2, rm } => {
                let a = self.f32_get(rs1);
                let b = self.f32_get(rs2);
                let res = Self::f32_sub(a, b, self.fp_rm(rm));
                self.f32_set_arith_bits(rd, res);
                Ok(nx)
            }
            Insn::FmulS { rd, rs1, rs2, rm } => {
                let a = self.f32_get(rs1);
                let b = self.f32_get(rs2);
                let res = Self::f32_mul(a, b, self.fp_rm(rm));
                self.f32_set_arith_bits(rd, res);
                Ok(nx)
            }
            Insn::FdivS { rd, rs1, rs2, rm } => {
                let a = self.f32_get(rs1);
                let b = self.f32_get(rs2);
                let res = Self::f32_div(a, b, self.fp_rm(rm));
                self.f32_set_arith_bits(rd, res);
                Ok(nx)
            }
            Insn::FsqrtS { rd, rs1, rm } => {
                let a = self.f32_get(rs1);
                let res = Self::f32_sqrt(a, self.fp_rm(rm));
                self.f32_set_arith_bits(rd, res);
                Ok(nx)
            }

            // Sign injection
            Insn::FsgnjS { rd, rs1, rs2 } => {
                let a = self.fregs.get_s(rs1);
                let b = self.fregs.get_s(rs2);
                let r = (a & 0x7fff_ffff) | (b & 0x8000_0000);
                self.f32_set_raw(rd, r);
                Ok(nx)
            }
            Insn::FsgnjnS { rd, rs1, rs2 } => {
                let a = self.fregs.get_s(rs1);
                let b = self.fregs.get_s(rs2);
                let r = (a & 0x7fff_ffff) | (!(b & 0x8000_0000) & 0x8000_0000);
                self.f32_set_raw(rd, r);
                Ok(nx)
            }
            Insn::FsgnjxS { rd, rs1, rs2 } => {
                let a = self.fregs.get_s(rs1);
                let b = self.fregs.get_s(rs2);
                let r = a ^ (b & 0x8000_0000);
                self.f32_set_raw(rd, r);
                Ok(nx)
            }

            // Min/max
            Insn::FminS { rd, rs1, rs2 } => {
                let a = self.f32_get(rs1);
                let b = self.f32_get(rs2);
                let (r, nv) = Self::f32_minmax(a, b, false);
                self.f32_set_arith_bits(
                    rd,
                    FpResult {
                        value: r.to_bits(),
                        flags: if nv { Self::FFLAG_NV } else { 0 },
                    },
                );
                Ok(nx)
            }
            Insn::FmaxS { rd, rs1, rs2 } => {
                let a = self.f32_get(rs1);
                let b = self.f32_get(rs2);
                let (r, nv) = Self::f32_minmax(a, b, true);
                self.f32_set_arith_bits(
                    rd,
                    FpResult {
                        value: r.to_bits(),
                        flags: if nv { Self::FFLAG_NV } else { 0 },
                    },
                );
                Ok(nx)
            }

            // FP -> integer conversion
            Insn::FcvtWS { rd, rs1, rm } => {
                let a = self.f32_get(rs1);
                let res = Self::f32_to_int(a as f64, self.fp_rm(rm), 32, false);
                self.set_fflag(res.flags);
                self.regs.set(rd, Self::sext32(res.value as u32));
                Ok(nx)
            }
            Insn::FcvtWuS { rd, rs1, rm } => {
                let a = self.f32_get(rs1);
                let res = Self::f32_to_int(a as f64, self.fp_rm(rm), 32, true);
                self.set_fflag(res.flags);
                self.regs.set(rd, res.value & 0xffff_ffff);
                Ok(nx)
            }
            Insn::FcvtLS { rd, rs1, rm } => {
                let a = self.f32_get(rs1);
                let res = Self::f32_to_int(a as f64, self.fp_rm(rm), 64, false);
                self.set_fflag(res.flags);
                self.regs.set(rd, res.value);
                Ok(nx)
            }
            Insn::FcvtLuS { rd, rs1, rm } => {
                let a = self.f32_get(rs1);
                let res = Self::f32_to_int(a as f64, self.fp_rm(rm), 64, true);
                self.set_fflag(res.flags);
                self.regs.set(rd, res.value);
                Ok(nx)
            }

            // FP -> integer move
            Insn::FmvXW { rd, rs1 } => {
                let r = self.fregs.get_s(rs1);
                self.regs.set(rd, Self::sext32(r));
                Ok(nx)
            }

            // Comparisons
            Insn::FeqS { rd, rs1, rs2 } => {
                let a = self.f32_get(rs1);
                let b = self.f32_get(rs2);
                let r = if a == b { 1 } else { 0 };
                self.regs.set(rd, r);
                Ok(nx)
            }
            Insn::FltS { rd, rs1, rs2 } => {
                let a = self.f32_get(rs1);
                let b = self.f32_get(rs2);
                let r = if a < b { 1 } else { 0 };
                if a.is_nan() || b.is_nan() {
                    self.set_fflag(Self::FFLAG_NV); // NV
                }
                self.regs.set(rd, r);
                Ok(nx)
            }
            Insn::FleS { rd, rs1, rs2 } => {
                let a = self.f32_get(rs1);
                let b = self.f32_get(rs2);
                let r = if a <= b { 1 } else { 0 };
                if a.is_nan() || b.is_nan() {
                    self.set_fflag(Self::FFLAG_NV); // NV
                }
                self.regs.set(rd, r);
                Ok(nx)
            }

            // Classification
            Insn::FclassS { rd, rs1 } => {
                let a = self.f32_get(rs1);
                self.regs.set(rd, Self::fclass_s(a));
                Ok(nx)
            }

            // Integer -> FP conversion
            Insn::FcvtSW { rd, rs1, rm } => {
                let a = self.regs.get(rs1);
                let source = Self::int_source(a, xlen, 32, false);
                let res = Self::int_to_f32(source, self.fp_rm(rm));
                self.f32_set_arith_bits(rd, res);
                Ok(nx)
            }
            Insn::FcvtSWu { rd, rs1, rm } => {
                let a = self.regs.get(rs1);
                let source = Self::int_source(a, xlen, 32, true);
                let res = Self::int_to_f32(source, self.fp_rm(rm));
                self.f32_set_arith_bits(rd, res);
                Ok(nx)
            }
            Insn::FcvtSL { rd, rs1, rm } => {
                let a = self.regs.get(rs1);
                let source = Self::int_source(a, xlen, 64, false);
                let res = Self::int_to_f32(source, self.fp_rm(rm));
                self.f32_set_arith_bits(rd, res);
                Ok(nx)
            }
            Insn::FcvtSLu { rd, rs1, rm } => {
                let a = self.regs.get(rs1);
                let source = Self::int_source(a, xlen, 64, true);
                let res = Self::int_to_f32(source, self.fp_rm(rm));
                self.f32_set_arith_bits(rd, res);
                Ok(nx)
            }

            // Integer -> FP move
            Insn::FmvWX { rd, rs1 } => {
                let r = self.regs.get(rs1) as u32;
                self.fregs.set_s(rd, r);
                Ok(nx)
            }

            // D (double-precision floating-point)

            // Loads/stores
            Insn::Fld { rd, rs1, imm } => {
                let addr = self.regs.get(rs1).wrapping_add(imm as u64);
                let v = self.load_le::<8>(mem, addr)?;
                self.fregs.set_d(rd, v);
                Ok(nx)
            }
            Insn::Fsd { rs1, rs2, imm } => {
                let addr = self.regs.get(rs1).wrapping_add(imm as u64);
                let v = self.fregs.get_d(rs2);
                self.store_le::<8>(mem, addr, v)?;
                Ok(nx)
            }

            // Fused multiply-add
            Insn::FmaddD {
                rd,
                rs1,
                rs2,
                rs3,
                rm,
            } => {
                let a = self.f64_get(rs1);
                let b = self.f64_get(rs2);
                let c = self.f64_get(rs3);
                let res = Self::f64_fma(a, b, c, self.fp_rm(rm), false, false);
                self.f64_set_arith_bits(rd, res);
                Ok(nx)
            }
            Insn::FmsubD {
                rd,
                rs1,
                rs2,
                rs3,
                rm,
            } => {
                let a = self.f64_get(rs1);
                let b = self.f64_get(rs2);
                let c = self.f64_get(rs3);
                let res = Self::f64_fma(a, b, c, self.fp_rm(rm), false, true);
                self.f64_set_arith_bits(rd, res);
                Ok(nx)
            }
            Insn::FnmsubD {
                rd,
                rs1,
                rs2,
                rs3,
                rm,
            } => {
                let a = self.f64_get(rs1);
                let b = self.f64_get(rs2);
                let c = self.f64_get(rs3);
                let res = Self::f64_fma(a, b, c, self.fp_rm(rm), true, false);
                self.f64_set_arith_bits(rd, res);
                Ok(nx)
            }
            Insn::FnmaddD {
                rd,
                rs1,
                rs2,
                rs3,
                rm,
            } => {
                let a = self.f64_get(rs1);
                let b = self.f64_get(rs2);
                let c = self.f64_get(rs3);
                let res = Self::f64_fma(a, b, c, self.fp_rm(rm), true, true);
                self.f64_set_arith_bits(rd, res);
                Ok(nx)
            }

            // Basic arithmetic
            Insn::FaddD { rd, rs1, rs2, rm } => {
                let a = self.f64_get(rs1);
                let b = self.f64_get(rs2);
                let res = Self::f64_add(a, b, self.fp_rm(rm));
                self.f64_set_arith_bits(rd, res);
                Ok(nx)
            }
            Insn::FsubD { rd, rs1, rs2, rm } => {
                let a = self.f64_get(rs1);
                let b = self.f64_get(rs2);
                let res = Self::f64_sub(a, b, self.fp_rm(rm));
                self.f64_set_arith_bits(rd, res);
                Ok(nx)
            }
            Insn::FmulD { rd, rs1, rs2, rm } => {
                let a = self.f64_get(rs1);
                let b = self.f64_get(rs2);
                let res = Self::f64_mul(a, b, self.fp_rm(rm));
                self.f64_set_arith_bits(rd, res);
                Ok(nx)
            }
            Insn::FdivD { rd, rs1, rs2, rm } => {
                let a = self.f64_get(rs1);
                let b = self.f64_get(rs2);
                let res = Self::f64_div(a, b, self.fp_rm(rm));
                self.f64_set_arith_bits(rd, res);
                Ok(nx)
            }
            Insn::FsqrtD { rd, rs1, rm } => {
                let a = self.f64_get(rs1);
                let res = Self::f64_sqrt(a, self.fp_rm(rm));
                self.f64_set_arith_bits(rd, res);
                Ok(nx)
            }

            // Sign injection
            Insn::FsgnjD { rd, rs1, rs2 } => {
                let a = self.fregs.get_d(rs1);
                let b = self.fregs.get_d(rs2);
                let r = (a & 0x7fff_ffff_ffff_ffff) | (b & 0x8000_0000_0000_0000);
                self.f64_set_raw(rd, r);
                Ok(nx)
            }
            Insn::FsgnjnD { rd, rs1, rs2 } => {
                let a = self.fregs.get_d(rs1);
                let b = self.fregs.get_d(rs2);
                let r = (a & 0x7fff_ffff_ffff_ffff) | ((!b) & 0x8000_0000_0000_0000);
                self.f64_set_raw(rd, r);
                Ok(nx)
            }
            Insn::FsgnjxD { rd, rs1, rs2 } => {
                let a = self.fregs.get_d(rs1);
                let b = self.fregs.get_d(rs2);
                let r = a ^ (b & 0x8000_0000_0000_0000);
                self.f64_set_raw(rd, r);
                Ok(nx)
            }

            // Min/max
            Insn::FminD { rd, rs1, rs2 } => {
                let a = self.f64_get(rs1);
                let b = self.f64_get(rs2);
                let (r, nv) = Self::f64_minmax(a, b, false);
                self.f64_set_arith_bits(
                    rd,
                    FpResult {
                        value: r.to_bits(),
                        flags: if nv { Self::FFLAG_NV } else { 0 },
                    },
                );
                Ok(nx)
            }
            Insn::FmaxD { rd, rs1, rs2 } => {
                let a = self.f64_get(rs1);
                let b = self.f64_get(rs2);
                let (r, nv) = Self::f64_minmax(a, b, true);
                self.f64_set_arith_bits(
                    rd,
                    FpResult {
                        value: r.to_bits(),
                        flags: if nv { Self::FFLAG_NV } else { 0 },
                    },
                );
                Ok(nx)
            }

            // FP -> FP conversion
            Insn::FcvtSD { rd, rs1, rm } => {
                let a = self.f64_get(rs1);
                let res = Self::round_f64_to_f32(a, self.fp_rm(rm), true);
                self.f32_set_arith_bits(rd, res);
                Ok(nx)
            }
            Insn::FcvtDS { rd, rs1, rm: _ } => {
                let a = self.f32_get(rs1);
                let res = Self::round_f32_to_f64(a);
                self.f64_set_arith_bits(rd, res);
                Ok(nx)
            }

            // FP -> integer conversion
            Insn::FcvtWD { rd, rs1, rm } => {
                let a = self.f64_get(rs1);
                let res = Self::f64_to_int(a, self.fp_rm(rm), 32, false);
                self.set_fflag(res.flags);
                self.regs.set(rd, Self::sext32(res.value as u32));
                Ok(nx)
            }
            Insn::FcvtWuD { rd, rs1, rm } => {
                let a = self.f64_get(rs1);
                let res = Self::f64_to_int(a, self.fp_rm(rm), 32, true);
                self.set_fflag(res.flags);
                self.regs.set(rd, res.value & 0xffff_ffff);
                Ok(nx)
            }
            Insn::FcvtLD { rd, rs1, rm } => {
                let a = self.f64_get(rs1);
                let res = Self::f64_to_int(a, self.fp_rm(rm), 64, false);
                self.set_fflag(res.flags);
                self.regs.set(rd, res.value);
                Ok(nx)
            }
            Insn::FcvtLuD { rd, rs1, rm } => {
                let a = self.f64_get(rs1);
                let res = Self::f64_to_int(a, self.fp_rm(rm), 64, true);
                self.set_fflag(res.flags);
                self.regs.set(rd, res.value);
                Ok(nx)
            }

            // FP -> integer move
            Insn::FmvXD { rd, rs1 } => {
                let r = self.fregs.get_d(rs1);
                self.regs.set(rd, r);
                Ok(nx)
            }

            // Comparisons
            Insn::FeqD { rd, rs1, rs2 } => {
                let a = self.f64_get(rs1);
                let b = self.f64_get(rs2);
                let r = if a == b { 1 } else { 0 };
                self.regs.set(rd, r);
                Ok(nx)
            }
            Insn::FltD { rd, rs1, rs2 } => {
                let a = self.f64_get(rs1);
                let b = self.f64_get(rs2);
                let r = if a < b { 1 } else { 0 };
                if a.is_nan() || b.is_nan() {
                    self.set_fflag(Self::FFLAG_NV); // NV
                }
                self.regs.set(rd, r);
                Ok(nx)
            }
            Insn::FleD { rd, rs1, rs2 } => {
                let a = self.f64_get(rs1);
                let b = self.f64_get(rs2);
                let r = if a <= b { 1 } else { 0 };
                if a.is_nan() || b.is_nan() {
                    self.set_fflag(Self::FFLAG_NV); // NV
                }
                self.regs.set(rd, r);
                Ok(nx)
            }

            // Classification
            Insn::FclassD { rd, rs1 } => {
                let a = self.f64_get(rs1);
                self.regs.set(rd, Self::fclass_d(a));
                Ok(nx)
            }

            // Integer -> FP conversion
            Insn::FcvtDW { rd, rs1, rm } => {
                let a = self.regs.get(rs1);
                let source = Self::int_source(a, xlen, 32, false);
                let res = Self::int_to_f64(source, self.fp_rm(rm));
                self.f64_set_arith_bits(rd, res);
                Ok(nx)
            }
            Insn::FcvtDWu { rd, rs1, rm } => {
                let a = self.regs.get(rs1);
                let source = Self::int_source(a, xlen, 32, true);
                let res = Self::int_to_f64(source, self.fp_rm(rm));
                self.f64_set_arith_bits(rd, res);
                Ok(nx)
            }
            Insn::FcvtDL { rd, rs1, rm } => {
                let a = self.regs.get(rs1);
                let source = Self::int_source(a, xlen, 64, false);
                let res = Self::int_to_f64(source, self.fp_rm(rm));
                self.f64_set_arith_bits(rd, res);
                Ok(nx)
            }
            Insn::FcvtDLu { rd, rs1, rm } => {
                let a = self.regs.get(rs1);
                let source = Self::int_source(a, xlen, 64, true);
                let res = Self::int_to_f64(source, self.fp_rm(rm));
                self.f64_set_arith_bits(rd, res);
                Ok(nx)
            }

            // Integer -> FP move
            Insn::FmvDX { rd, rs1 } => {
                let r = self.regs.get(rs1);
                self.fregs.set_d(rd, r);
                Ok(nx)
            }

            _ => unreachable!(),
        }
    }

    fn amo<const N: usize, F>(
        &mut self,
        mem: &mut PhysMem,
        rd: u8,
        rs1: u8,
        rs2: u8,
        op: F,
    ) -> Result<u64, ExecError>
    where
        F: FnOnce(u64, u64) -> u64,
    {
        let addr = self.regs.get(rs1);
        let old = if N == 4 {
            self.load_le::<4>(mem, addr)?
        } else {
            self.load_le::<8>(mem, addr)?
        };
        let new = op(old, self.regs.get(rs2));
        if N == 4 {
            self.store_le::<4>(mem, addr, new)?;
            self.regs.set(rd, old as i32 as i64 as u64);
        } else {
            self.store_le::<8>(mem, addr, new)?;
            self.regs.set(rd, old);
        }
        Ok(self.regs.pc.wrapping_add(self.inst_len as u64))
    }

    fn amocas<const N: usize>(
        &mut self,
        mem: &mut PhysMem,
        rd: u8,
        rs1: u8,
        rs2: u8,
    ) -> Result<u64, ExecError> {
        let addr = self.regs.get(rs1);
        let old = if N == 4 {
            self.load_le::<4>(mem, addr)?
        } else {
            self.load_le::<8>(mem, addr)?
        };
        let expected = self.regs.get(rd);
        let new = self.regs.get(rs2);
        let swap = if N == 4 {
            (old as u32) == (expected as u32)
        } else {
            old == expected
        };
        if swap {
            if N == 4 {
                self.store_le::<4>(mem, addr, new as u32 as u64)?;
                self.regs.set(rd, old as i32 as i64 as u64);
            } else {
                self.store_le::<8>(mem, addr, new)?;
                self.regs.set(rd, old);
            }
        } else {
            self.regs.set(
                rd,
                if N == 4 {
                    old as i32 as i64 as u64
                } else {
                    old
                },
            );
        }
        Ok(self.regs.pc.wrapping_add(self.inst_len as u64))
    }

    fn mret(&mut self) {
        let mstatus = self.csr.mstatus;
        let mpp = (mstatus >> 11) & 0x3;
        let mpie = (mstatus >> 7) & 1;
        let new_mstatus = (mstatus & !(0x3 << 11))      // MPP = U
            | (mpie << 3)                              // MIE <- MPIE
            | (1u64 << 7); // MPIE = 1
        self.csr.mstatus = new_mstatus;
        self.csr.set_mode(mpp as u8);
        self.regs.pc = self.csr.mepc;
    }

    /// Translate a virtual address through `satp`, or pass through when bare.
    ///
    /// On a translation failure `fault_addr` is set to the original virtual
    /// address and `ExecError::Trap(cause)` is returned.
    fn translate(&mut self, mem: &PhysMem, vaddr: u64, cause: u64) -> Result<u64, ExecError> {
        match mmu::translate(mem, &self.mmu, self.csr.satp, vaddr) {
            Ok(paddr) => Ok(paddr),
            Err(_) => {
                self.fault_addr = vaddr;
                Err(ExecError::Trap(cause))
            }
        }
    }

    fn load_sext<const N: usize>(&mut self, mem: &PhysMem, vaddr: u64) -> Result<i64, ExecError> {
        let paddr = self.translate(mem, vaddr, 13)?;
        mem.read_sext::<N>(paddr).map_err(|_| {
            self.fault_addr = vaddr;
            ExecError::Trap(5)
        })
    }

    fn load_le<const N: usize>(&mut self, mem: &PhysMem, vaddr: u64) -> Result<u64, ExecError> {
        let paddr = self.translate(mem, vaddr, 13)?;
        mem.read_le::<N>(paddr).map_err(|_| {
            self.fault_addr = vaddr;
            ExecError::Trap(5)
        })
    }

    fn store_le<const N: usize>(
        &mut self,
        mem: &mut PhysMem,
        vaddr: u64,
        val: u64,
    ) -> Result<(), ExecError> {
        let paddr = self.translate(mem, vaddr, 15)?;
        mem.write_le::<N>(paddr, val).map_err(|_| {
            self.fault_addr = vaddr;
            ExecError::Trap(7)
        })
    }

    fn sret(&mut self) {
        let mstatus = self.csr.mstatus;
        let spp = (mstatus >> 8) & 1;
        let spie = (mstatus >> 5) & 1;
        let new_mstatus = (mstatus & !(1u64 << 8))      // SPP = U
            | (spie << 1)                              // SIE <- SPIE
            | (1u64 << 5); // SPIE = 1
        self.csr.mstatus = new_mstatus;
        self.csr.set_mode(spp as u8);
        self.regs.pc = self.csr.sepc;
    }

    fn take_trap(&mut self, cause: u64) {
        let prev_mode = self.csr.mode();
        let idx = if (cause >> 63) & 1 != 0 {
            cause & 0xfff
        } else {
            cause
        };
        let delegated = if (cause >> 63) & 1 != 0 {
            (self.csr.mideleg >> idx) & 1 != 0
        } else {
            (self.csr.medeleg >> idx) & 1 != 0
        };

        if delegated && prev_mode <= 1 {
            // S-mode trap.
            self.csr.sepc = self.regs.pc;
            self.csr.scause = cause;
            self.csr.stval = self.fault_addr;
            let mstatus = self.csr.mstatus;
            let sie = (mstatus >> 1) & 1;
            let spp = if prev_mode == 0 { 0 } else { 1 };
            let new_mstatus = (mstatus & !((1u64 << 5) | (1u64 << 1) | (1u64 << 8)))
                | (sie << 5)            // SPIE <- SIE
                | (spp << 8); // SPP <- previous mode
            self.csr.mstatus = new_mstatus;
            self.csr.set_mode(1);
            let base = self.csr.stvec & !0b11u64;
            self.regs.pc = base;
        } else {
            // M-mode trap.
            self.csr.mepc = self.regs.pc;
            self.csr.mcause = cause;
            self.csr.mtval = self.fault_addr;
            let mstatus = self.csr.mstatus;
            let mie = (mstatus >> 3) & 1;
            let new_mstatus = (mstatus & !((1u64 << 7) | (1u64 << 3) | (0x3u64 << 11)))
                | (mie << 7)                    // MPIE <- MIE
                | ((prev_mode as u64) << 11); // MPP <- previous mode
            self.csr.mstatus = new_mstatus;
            self.csr.set_mode(3);
            let base = self.csr.mtvec & !0b11u64;
            self.regs.pc = base;
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn record(
        &mut self,
        pc_rdata: u64,
        pc_wdata: u64,
        insn: u32,
        trap: bool,
        cause: u64,
        halt: bool,
        rd_addr: u8,
        rd_wdata: u64,
        frd_addr: u8,
        frd_wdata: u64,
    ) {
        self.records.push(CommitRecord {
            order: self.record_order,
            hart: 0,
            pc_rdata,
            pc_wdata,
            insn,
            trap,
            cause,
            prv: self.csr.mode(),
            halt,
            rd_addr,
            rd_wdata,
            frd_addr,
            frd_wdata,
        });
        self.record_order += 1;
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ExecError {
    /// A synchronous exception, carrying `mcause`.
    Trap(u64),
}

#[cfg(test)]
#[allow(clippy::precedence, clippy::too_many_arguments)]
mod tests {
    use super::*;
    use crate::mem::{PhysMem, Region};

    fn hart() -> Hart {
        let mut h = Hart::new(0x8000_0000);
        h.csr.mtvec = 0x7000_0000;
        h.mmu = Mmu::sv39();
        h
    }

    fn mem() -> PhysMem {
        let mut m = PhysMem::new();
        m.add(Region::new(0x8000_0000, 0x1000));
        m.add(Region::new(0x7000_0000, 0x1000));
        m.write_le::<4>(0x7000_0000, 0x0000_006f).unwrap(); // jal x0, 0
        m.add(Region::new(0x6000_0000, 0x1000));
        m.write_le::<4>(0x6000_0000, 0x0000_006f).unwrap(); // jal x0, 0
        m
    }

    #[test]
    fn checkpoint_captures_and_restores_pc_and_registers() {
        let mut h = hart();
        let m = mem();
        h.regs.set(1, 0x1234);
        h.fregs.set_d(1, 0x1122_3344_5566_7788);
        h.csr.mscratch = 0xabcd;
        let cp = h.checkpoint(&m);
        assert_eq!(cp.pc, 0x8000_0000);
        assert_eq!(cp.x[1], 0x1234);
        assert_eq!(cp.f[1], 0x1122_3344_5566_7788);
        assert!(cp.csr.iter().any(|(k, v)| k == "mscratch" && *v == 0xabcd));
        assert_eq!(cp.memory.len(), 3);

        let mut h2 = Hart::new(0);
        let mut m2 = PhysMem::new();
        m2.add(Region::new(0x8000_0000, 0x1000));
        m2.add(Region::new(0x7000_0000, 0x1000));
        m2.add(Region::new(0x6000_0000, 0x1000));
        h2.restore(&mut m2, &cp);
        assert_eq!(h2.regs.pc, 0x8000_0000);
        assert_eq!(h2.regs.get(1), 0x1234);
        assert_eq!(h2.fregs.get_d(1), 0x1122_3344_5566_7788);
        assert_eq!(h2.csr.mscratch, 0xabcd);
        assert_eq!(m2.read_le::<4>(0x7000_0000).unwrap(), 0x0000_006f);
    }

    #[test]
    fn checkpoint_captures_and_restores_devices() {
        use crate::device::{Clint, Plic, Uart};
        use crate::mem::{Device, DeviceKind};
        let h = hart();
        let mut m = PhysMem::new();
        m.add(Region::new(0x8000_0000, 0x1000));
        m.add_device(Device::new(
            0x0200_0000,
            0x10000,
            DeviceKind::Clint(Clint::new(2)),
        ));
        m.add_device(Device::new(
            0x0c00_0000,
            0x40_0000,
            DeviceKind::Plic(Plic::new(30, 16)),
        ));
        m.add_device(Device::new(
            0x1000_0000,
            0x100,
            DeviceKind::Uart(Uart::new()),
        ));

        // Drive some device state.
        m.write_le::<1>(0x1000_0000, b'A' as u64).unwrap();
        m.clint_mut().unwrap().mtime = 0x1234_5678_9abc_def0;
        m.clint_mut().unwrap().msip[0] = 1;
        m.clint_mut().unwrap().mtimecmp[1] = 0xdeadbeef;
        m.plic_mut().unwrap().pending = 0b1010;
        m.plic_mut().unwrap().enable[0] = 0b1111;

        let cp = h.checkpoint(&m);
        assert_eq!(cp.devices.len(), 3);
        assert!(cp.devices.iter().any(|d| d.kind == "clint"));
        assert!(cp.devices.iter().any(|d| d.kind == "plic"));
        assert!(cp.devices.iter().any(|d| d.kind == "uart"));

        // Rebuild an empty memory map and restore.
        let mut h2 = Hart::new(0x8000_0000);
        let mut m2 = PhysMem::new();
        m2.add(Region::new(0x8000_0000, 0x1000));
        m2.add_device(Device::new(
            0x0200_0000,
            0x10000,
            DeviceKind::Clint(Clint::new(2)),
        ));
        m2.add_device(Device::new(
            0x0c00_0000,
            0x40_0000,
            DeviceKind::Plic(Plic::new(30, 16)),
        ));
        m2.add_device(Device::new(
            0x1000_0000,
            0x100,
            DeviceKind::Uart(Uart::new()),
        ));
        h2.restore(&mut m2, &cp);

        assert_eq!(m2.uart().unwrap().output, vec![b'A']);
        assert_eq!(m2.clint().unwrap().mtime, 0x1234_5678_9abc_def0);
        assert_eq!(m2.clint().unwrap().msip[0], 1);
        assert_eq!(m2.clint().unwrap().mtimecmp[1], 0xdeadbeef);
        assert_eq!(m2.plic().unwrap().pending, 0b1010);
        assert_eq!(m2.plic().unwrap().enable[0], 0b1111);
    }

    #[test]
    fn run_replay_matches_a_reference_record_stream() {
        let mut h = hart();
        let mut m = mem();

        // Run a few steps to generate a reference.
        assert_eq!(h.run(&mut m, 64, 4), Halt::StepLimit);
        let reference = h.records.clone();

        // A fresh hart at the same starting state should replay identically.
        let mut h2 = hart();
        let mut m2 = mem();
        assert_eq!(
            h2.run_replay(&mut m2, 64, reference.len() as u64, &reference),
            Halt::StepLimit
        );

        // A reference with a deliberately wrong pc_wdata should diverge at the first record.
        let mut wrong = reference.clone();
        wrong[0].pc_wdata = 0xdeadbeef;
        let mut h3 = hart();
        let mut m3 = mem();
        assert!(matches!(
            h3.run_replay(&mut m3, 64, wrong.len() as u64, &wrong),
            Halt::ReplayDivergence(0, _)
        ));

        // A run that is longer than the reference should diverge on length.
        let mut h4 = hart();
        let mut m4 = mem();
        assert!(matches!(
            h4.run_replay(&mut m4, 64, 100, &reference[..2]),
            Halt::ReplayDivergence(2, _)
        ));
    }

    fn write_i(m: &mut PhysMem, addr: u64, op: u32, rd: u32, f3: u32, rs1: u32, imm: i64) {
        // 12-bit two's-complement immediate in bits 31:20.
        let imm12 = ((imm as i32) & 0xfff) as u32;
        let w = imm12 << 20 | rs1 << 15 | f3 << 12 | rd << 7 | op;
        m.write_le::<4>(addr, w.into()).unwrap();
    }

    fn write_shifti(m: &mut PhysMem, addr: u64, op: u32, rd: u32, f3: u32, rs1: u32, shamt: u32) {
        // I-type shift: the 6-bit shamt is in bits 25:20, funct7 in 31:26.
        let funct7 = if f3 == 5 && shamt >= 0x20 { 0x20 } else { 0 };
        let w = funct7 << 26 | shamt << 20 | rs1 << 15 | f3 << 12 | rd << 7 | op;
        m.write_le::<4>(addr, w.into()).unwrap();
    }

    fn write_slli_uw(m: &mut PhysMem, addr: u64, rd: u32, rs1: u32, shamt: u32) {
        // slli.uw: funct6=0b000010 in 31:26, shamt in 25:20, f3=001, op=0x1b.
        let w = 0x02 << 26 | shamt << 20 | rs1 << 15 | 0x1 << 12 | rd << 7 | 0x1b;
        m.write_le::<4>(addr, w.into()).unwrap();
    }

    fn write_r(m: &mut PhysMem, addr: u64, op: u32, rd: u32, f3: u32, rs1: u32, rs2: u32, f7: u32) {
        let w = f7 << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | rd << 7 | op;
        m.write_le::<4>(addr, w.into()).unwrap();
    }

    fn write_u(m: &mut PhysMem, addr: u64, op: u32, rd: u32, imm: u32) {
        // U-type: the immediate is the upper 20 bits of a 32-bit word.
        let w = (imm << 12) | (rd << 7) | op;
        m.write_le::<4>(addr, w.into()).unwrap();
    }

    fn write_s(m: &mut PhysMem, addr: u64, op: u32, f3: u32, rs1: u32, rs2: u32, imm: i64) {
        // S-type: imm[11:5] in [31:25], imm[4:0] in [11:7].
        let imm12 = ((imm as i32) & 0xfff) as u32;
        let hi = (imm12 >> 5) & 0x7f; // bits 11:5
        let lo = imm12 & 0x1f; // bits 4:0
        let w = (hi << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (lo << 7) | op;
        m.write_le::<4>(addr, w.into()).unwrap();
    }

    fn write_b(m: &mut PhysMem, addr: u64, f3: u32, rs1: u32, rs2: u32, off: i64) {
        let o = off as u32;
        let b12 = (o >> 12) & 1;
        let b10_5 = (o >> 5) & 0x3f;
        let b4_1 = (o >> 1) & 0x0f;
        let b11 = (o >> 11) & 1;
        let w = (b12 << 31)
            | (b10_5 << 25)
            | (rs2 << 20)
            | (rs1 << 15)
            | (f3 << 12)
            | (b4_1 << 8)
            | (b11 << 7)
            | 0x63;
        m.write_le::<4>(addr, w.into()).unwrap();
    }

    fn write_j(m: &mut PhysMem, addr: u64, rd: u32, off: i64) {
        let o = off as u32;
        let bit20 = (o >> 20) & 1;
        let bits10_1 = (o >> 1) & 0x3ff;
        let bit11 = (o >> 11) & 1;
        let bits19_12 = (o >> 12) & 0xff;
        let w =
            (bit20 << 31) | (bits19_12 << 12) | (bit11 << 20) | (bits10_1 << 21) | (rd << 7) | 0x6f;
        m.write_le::<4>(addr, w.into()).unwrap();
    }

    #[test]
    fn addi_add_sub_store_and_load_loop() {
        let mut h = hart();
        let mut m = mem();

        // x1 = 6; x2 = 0; loop: x1 = x1 - 1; x2 = x2 + x1; if x1 != 0 goto loop
        // Sum is 5+4+3+2+1 = 15.
        h.regs.set(1, 6);
        h.regs.set(10, 0x8000_0100); // pointer to the store slot
        write_i(&mut m, 0x8000_0000, 0x13, 2, 0, 0, 0); // addi x2, x0, 0
        write_i(&mut m, 0x8000_0004, 0x13, 1, 0, 1, -1); // addi x1, x1, -1
        write_r(&mut m, 0x8000_0008, 0x33, 2, 0, 2, 1, 0x00); // add x2, x2, x1
        write_b(&mut m, 0x8000_000c, 0x1, 1, 0, -8); // bne x1, x0, -8
        write_s(&mut m, 0x8000_0010, 0x23, 3, 10, 2, 0); // sd x2, 0(x10)
        write_i(&mut m, 0x8000_0014, 0x03, 3, 3, 10, 0); // ld x3, 0(x10)
        write_i(&mut m, 0x8000_0018, 0x73, 0, 0, 0, 0); // ecall

        let halt = h.run(&mut m, 64, 100);
        if halt != Halt::StepLimit {
            for (i, r) in h.records.iter().rev().take(10).rev().enumerate() {
                eprintln!(
                    "{i}: pc={:#x} insn={:#010x} rd={} w={:#x}",
                    r.pc_rdata, r.insn, r.rd_addr, r.rd_wdata
                );
            }
            eprintln!("fault pc = {:#x}", h.regs.pc);
        }
        assert_eq!(halt, Halt::StepLimit);
        assert_eq!(h.regs.get(2), 15, "5 + 4 + 3 + 2 + 1 = 15");
        assert_eq!(h.regs.get(3), 15, "loaded value");
        // ecall now traps to the self-loop; there is at least one extra record.
        assert!(h.records.len() >= 22);
    }

    #[test]
    fn jal_jalr_call_and_return() {
        let mut h = hart();
        let mut m = mem();

        // 0x8000_0000: jal x1, 8   -> call sub at 0x8000_0008
        // 0x8000_0004: ecall       (main returns)
        // 0x8000_0008: addi x2, x0, 42
        // 0x8000_000c: jalr x0, x1, 0  -> return
        write_j(&mut m, 0x8000_0000, 1, 8);
        write_i(&mut m, 0x8000_0004, 0x73, 0, 0, 0, 0);
        write_i(&mut m, 0x8000_0008, 0x13, 2, 0, 0, 42);
        write_i(&mut m, 0x8000_000c, 0x67, 0, 0, 1, 0);

        assert_eq!(h.run(&mut m, 64, 20), Halt::StepLimit);
        assert_eq!(h.regs.get(2), 42);
        assert_eq!(h.regs.get(1), 0x8000_0004);
    }

    #[test]
    fn branch_sign_and_unsigned_compare() {
        let mut h = hart();
        let mut m = mem();

        // x1 = -1, x2 = 1; blt x1, x2, 8 -> taken; x3 = 99; bltu x1, x2, 8 -> NOT taken; x4 = 99
        write_i(&mut m, 0x8000_0000, 0x13, 1, 0, 0, -1);
        write_i(&mut m, 0x8000_0004, 0x13, 2, 0, 0, 1);
        write_b(&mut m, 0x8000_0008, 0x4, 1, 2, 8); // blt
        write_i(&mut m, 0x8000_000c, 0x13, 3, 0, 0, 0xff);
        write_i(&mut m, 0x8000_0010, 0x13, 3, 0, 0, 99);
        write_b(&mut m, 0x8000_0014, 0x6, 1, 2, 8); // bltu
        write_i(&mut m, 0x8000_0018, 0x13, 4, 0, 0, 0xff);
        write_i(&mut m, 0x8000_001c, 0x73, 0, 0, 0, 0);

        assert_eq!(h.run(&mut m, 64, 20), Halt::StepLimit);
        assert_eq!(h.regs.get(3), 99, "blt taken");
        // bltu x1(-1 as unsigned = max), x2(1) is NOT taken, so we fall through to x4=0xff.
        assert_eq!(h.regs.get(4), 0xff, "bltu not taken");
    }

    #[test]
    fn shift_and_logical_ops() {
        let mut h = hart();
        let mut m = mem();

        // x1 = 0b1111; x2 = x1 << 2; x3 = x2 >> 2; x4 = x2 s>> 3; x5 = x1 & ~1; x6 = x1 | 2; x7 = x1 ^ 0x0f
        write_i(&mut m, 0x8000_0000, 0x13, 1, 0, 0, 0x0f);
        write_shifti(&mut m, 0x8000_0004, 0x13, 2, 1, 1, 2); // slli x2, x1, 2
        write_shifti(&mut m, 0x8000_0008, 0x13, 3, 5, 2, 2); // srli x3, x2, 2
        write_shifti(&mut m, 0x8000_000c, 0x13, 4, 5, 2, 3); // srai x4, x2, 3
        write_i(&mut m, 0x8000_0010, 0x13, 5, 7, 1, -2); // andi with 0xfffe
        write_i(&mut m, 0x8000_0014, 0x13, 6, 6, 1, 2); // ori
        write_i(&mut m, 0x8000_0018, 0x13, 7, 4, 1, 0x0f); // xori
        write_i(&mut m, 0x8000_001c, 0x73, 0, 0, 0, 0);

        assert_eq!(h.run(&mut m, 64, 20), Halt::StepLimit);
        assert_eq!(h.regs.get(2), 0x3c);
        assert_eq!(h.regs.get(3), 0x0f);
        assert_eq!(h.regs.get(4), 0x07);
        assert_eq!(h.regs.get(5), 0x0e);
        assert_eq!(h.regs.get(6), 0x0f);
        assert_eq!(h.regs.get(7), 0);
    }

    #[test]
    fn compressed_executes_from_halfword_address() {
        // With the C extension, a 16-bit instruction may start on any 2-byte boundary and
        // advances the PC by 2 rather than 4.
        let mut h = hart();
        let mut m = mem();
        h.regs.pc = 0x8000_0002;
        // c.li x5, 3 -> op=01, funct3=010, rd=5, imm=3
        let c_li = 0x4000u16 | (5 << 7) | (3 << 2) | 0b01;
        m.write_le::<2>(0x8000_0002, c_li as u64).unwrap();
        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.regs.get(5), 3);
        assert_eq!(h.regs.pc, 0x8000_0004);
    }

    #[test]
    fn compressed_all_zero_halfword_is_illegal() {
        let mut h = hart();
        let mut m = mem();
        h.regs.pc = 0x8000_0002;
        m.write_le::<2>(0x8000_0002, 0).unwrap();
        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.csr.mcause, 2);
    }

    #[test]
    fn compressed_control_flow_and_stack_ops() {
        let mut h = hart();
        let mut m = mem();
        h.regs.set(2, 0x8000_0800); // sp

        // c.li x10, 7
        m.write_le::<2>(
            0x8000_0000,
            (0x4000u16 | (10 << 7) | (7 << 2) | 0b01) as u64,
        )
        .unwrap();
        // c.mv x11, x10 -> op=10, funct3=100, bit12=0, rd=11, rs2=10
        m.write_le::<2>(
            0x8000_0002,
            (0x8000u16 | (11 << 7) | (10 << 2) | 0b10) as u64,
        )
        .unwrap();
        // c.add x11, x10 -> bit12=1
        m.write_le::<2>(
            0x8000_0004,
            (0x8000u16 | (1 << 12) | (11 << 7) | (10 << 2) | 0b10) as u64,
        )
        .unwrap();
        // c.sdsp x11, 0(sp) -> op=10, funct3=111, uimm=0, rs2=11
        m.write_le::<2>(0x8000_0006, (0xe000u16 | (11 << 2) | 0b10) as u64)
            .unwrap();
        // c.ldsp x12, 0(sp) -> op=10, funct3=011, rd=12
        m.write_le::<2>(0x8000_0008, (0x6000u16 | (12 << 7) | 0b10) as u64)
            .unwrap();

        assert_eq!(h.run(&mut m, 64, 5), Halt::StepLimit);
        assert_eq!(h.regs.get(10), 7);
        assert_eq!(h.regs.get(11), 14);
        assert_eq!(h.regs.get(12), 14);
        assert_eq!(h.regs.pc, 0x8000_000a);
    }

    #[test]
    fn mul_div_rem_32_and_64() {
        let mut h = hart();
        let mut m = mem();

        h.regs.set(1, 7);
        h.regs.set(2, 3);
        h.regs.set(3, 0xffff_ffff_ffff_fff9); // -7

        // mul x4, x1, x2 -> 21
        write_r(&mut m, 0x8000_0000, 0x33, 4, 0, 1, 2, 0x01);
        // div x5, x1, x2 -> 2
        write_r(&mut m, 0x8000_0004, 0x33, 5, 4, 1, 2, 0x01);
        // rem x6, x1, x2 -> 1
        write_r(&mut m, 0x8000_0008, 0x33, 6, 6, 1, 2, 0x01);
        // div x7, x3, x2 -> -2
        write_r(&mut m, 0x8000_000c, 0x33, 7, 4, 3, 2, 0x01);
        // mulw x8, x1, x2 -> 21
        write_r(&mut m, 0x8000_0010, 0x3b, 8, 0, 1, 2, 0x01);
        // divuw x9, x1, x2 -> 2
        write_r(&mut m, 0x8000_0014, 0x3b, 9, 5, 1, 2, 0x01);
        write_i(&mut m, 0x8000_0018, 0x73, 0, 0, 0, 0);

        assert_eq!(h.run(&mut m, 64, 20), Halt::StepLimit);
        assert_eq!(h.regs.get(4), 21);
        assert_eq!(h.regs.get(5), 2);
        assert_eq!(h.regs.get(6), 1);
        assert_eq!(h.regs.get(7), -2i64 as u64);
        assert_eq!(h.regs.get(8), 21);
        assert_eq!(h.regs.get(9), 2);
    }

    #[test]
    fn division_by_zero_returns_all_ones() {
        let mut h = hart();
        let mut m = mem();

        h.regs.set(1, 5);
        // div x2, x1, x0 -> x0=0, result -1
        write_r(&mut m, 0x8000_0000, 0x33, 2, 4, 1, 0, 0x01);
        // divu x3, x1, x0 -> result u64::MAX
        write_r(&mut m, 0x8000_0004, 0x33, 3, 5, 1, 0, 0x01);
        write_i(&mut m, 0x8000_0008, 0x73, 0, 0, 0, 0);

        assert_eq!(h.run(&mut m, 64, 10), Halt::StepLimit);
        assert_eq!(h.regs.get(2), -1i64 as u64);
        assert_eq!(h.regs.get(3), u64::MAX);
    }

    fn write_amo(m: &mut PhysMem, addr: u64, rd: u32, f3: u32, rs1: u32, rs2: u32, funct5: u32) {
        let w = (funct5 << 27) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x2f;
        m.write_le::<4>(addr, w.into()).unwrap();
    }

    fn write_priv(m: &mut PhysMem, addr: u64, funct7: u32, rs2: u32) {
        let w = (funct7 << 25) | (rs2 << 20) | 0x73;
        m.write_le::<4>(addr, w.into()).unwrap();
    }

    fn write_fp_i(m: &mut PhysMem, addr: u64, rd: u32, rs1: u32, imm: i64) {
        // FLW: opcode 0x07, funct3=0x2.
        write_i(m, addr, 0x07, rd, 0x2, rs1, imm);
    }

    fn write_fp_d_i(m: &mut PhysMem, addr: u64, rd: u32, rs1: u32, imm: i64) {
        // FLD: opcode 0x07, funct3=0x3.
        write_i(m, addr, 0x07, rd, 0x3, rs1, imm);
    }

    fn write_fp_s(m: &mut PhysMem, addr: u64, rs1: u32, rs2: u32, imm: i64) {
        // FSW: opcode 0x27, funct3=0x2.
        write_s(m, addr, 0x27, 0x2, rs1, rs2, imm);
    }

    fn write_fp_d_s(m: &mut PhysMem, addr: u64, rs1: u32, rs2: u32, imm: i64) {
        // FSD: opcode 0x27, funct3=0x3.
        write_s(m, addr, 0x27, 0x3, rs1, rs2, imm);
    }

    fn write_fp_r(m: &mut PhysMem, addr: u64, rd: u32, f3: u32, rs1: u32, rs2: u32, f7: u32) {
        // OP-FP: opcode 0x53.
        write_r(m, addr, 0x53, rd, f3, rs1, rs2, f7);
    }

    fn write_fp_r4(
        m: &mut PhysMem,
        addr: u64,
        op: u32,
        rd: u32,
        rs1: u32,
        rs2: u32,
        rs3: u32,
        rm: u32,
        fmt: u32,
    ) {
        // R4-type: fmt in bits 26:25 (00 = S, 01 = D).
        let w = (rs3 << 27) | (fmt << 25) | (rs2 << 20) | (rs1 << 15) | (rm << 12) | (rd << 7) | op;
        m.write_le::<4>(addr, w.into()).unwrap();
    }

    fn write_csr(m: &mut PhysMem, addr: u64, rd: u32, rs1: u32, csr: u32) {
        // CSRRW: opcode 0x73, funct3=0x1, csr in bits 31:20.
        write_i(m, addr, 0x73, rd, 0x1, rs1, csr as i64);
    }

    fn nan_box(bits: u32) -> u64 {
        0xffff_ffff_0000_0000 | (bits as u64)
    }

    #[test]
    fn lr_sc_and_amo_word_update_memory() {
        let mut h = hart();
        let mut m = mem();
        m.add(Region::new(0x9000_0000, 0x1000));
        h.regs.set(10, 0x9000_0000);
        h.regs.set(11, 5);

        // lr.w x1, 0(x10) -> x1 = 0
        write_amo(&mut m, 0x8000_0000, 1, 2, 10, 0, 0x02);
        // amoadd.w x2, x11, 0(x10) -> x2 = 0, mem = 5
        write_amo(&mut m, 0x8000_0004, 2, 2, 10, 11, 0x00);
        // amoswap.w x3, x11, 0(x10) -> x3 = 5, mem = 5
        write_amo(&mut m, 0x8000_0008, 3, 2, 10, 11, 0x01);
        // sc.w x4, x11, 0(x10) -> x4 = 0, mem = 5 (reservation from lr still active)
        write_amo(&mut m, 0x8000_000c, 4, 2, 10, 11, 0x03);
        // lr.d x5, 0(x10) -> x5 = 5, new reservation
        write_amo(&mut m, 0x8000_0010, 5, 3, 10, 0, 0x02);
        // sc.d x6, x11, 0(x10) -> x6 = 0
        write_amo(&mut m, 0x8000_0014, 6, 3, 10, 11, 0x03);
        // sc.w x7, x11, 0x10(x10) -> x7 = 1 (no reservation)
        write_amo(&mut m, 0x8000_0018, 7, 2, 10, 11, 0x03);
        // offset is 0 because I-type S is encoded with rs2 as value? Wait sc encoding uses rs2 directly, not offset. So address is x10 + 0.
        write_i(&mut m, 0x8000_001c, 0x73, 0, 0, 0, 0);

        assert_eq!(h.run(&mut m, 64, 20), Halt::StepLimit);
        assert_eq!(h.regs.get(1), 0);
        assert_eq!(h.regs.get(2), 0);
        assert_eq!(h.regs.get(3), 5);
        assert_eq!(h.regs.get(4), 0);
        assert_eq!(h.regs.get(5), 5);
        assert_eq!(h.regs.get(6), 0);
        assert_eq!(h.regs.get(7), 1);
    }

    #[test]
    fn amocas_word_swaps_when_expected_and_fails_when_not() {
        let mut h = hart();
        let mut m = mem();
        m.add(Region::new(0x9000_0000, 0x1000));
        m.write_le::<4>(0x9000_0000, 0x1234_5678).unwrap();
        h.regs.set(10, 0x9000_0000);
        h.regs.set(11, 0x1234_5678u64 as i32 as i64 as u64); // expected (will sign-extend)
        h.regs.set(12, 0xabcd_1234u64 as i32 as i64 as u64); // new

        // amocas.w x11, x12, 0(x10) -> rd=11, rs1=10, rs2=12, funct5=0x05
        write_amo(&mut m, 0x8000_0000, 11, 2, 10, 12, 0x05);
        // amocas.w x13, x11, 0(x10): expected in x13 is wrong
        h.regs.set(13, 0);
        // rd=13, rs1=10, rs2=11 (expected in rd=13, new in rs2=11)
        write_amo(&mut m, 0x8000_0004, 13, 2, 10, 11, 0x05);
        write_i(&mut m, 0x8000_0008, 0x73, 0, 0, 0, 0);

        assert_eq!(h.run(&mut m, 64, 10), Halt::StepLimit);
        // First cas should swap: rd gets old (0x1234_5678 sign-extended), mem becomes 0xabcd_1234.
        assert_eq!(h.regs.get(11), 0x1234_5678u64 as i32 as i64 as u64);
        assert_eq!(m.read_le::<4>(0x9000_0000).unwrap(), 0xabcd_1234);
        // Second cas expected 0, old is 0xabcd_1234 -> fails, rd gets old.
        assert_eq!(h.regs.get(13), 0xabcd_1234u64 as i32 as i64 as u64);
    }

    #[test]
    fn zba_shifts_and_adds_compute_indexed_addresses() {
        let mut h = hart();
        let mut m = mem();
        h.regs.set(1, 10);
        h.regs.set(2, 3);
        // sh1add x3, x1, x2 -> 10 + (3 << 1) = 16
        write_r(&mut m, 0x8000_0000, 0x33, 3, 2, 1, 2, 0x10);
        // sh2add x4, x1, x2 -> 10 + (3 << 2) = 22
        write_r(&mut m, 0x8000_0004, 0x33, 4, 4, 1, 2, 0x10);
        // sh3add x5, x1, x2 -> 10 + (3 << 3) = 34
        write_r(&mut m, 0x8000_0008, 0x33, 5, 6, 1, 2, 0x10);
        write_i(&mut m, 0x8000_000c, 0x73, 0, 0, 0, 0);

        assert_eq!(h.run(&mut m, 64, 10), Halt::StepLimit);
        assert_eq!(h.regs.get(3), 16);
        assert_eq!(h.regs.get(4), 22);
        assert_eq!(h.regs.get(5), 34);
    }

    #[test]
    fn zbs_single_bit_operations() {
        let mut h = hart();
        let mut m = mem();
        h.regs.set(1, 0x0000_0000_0000_00f0);
        h.regs.set(2, 4);
        // bset x3, x1, x2 -> set bit 4
        write_r(&mut m, 0x8000_0000, 0x33, 3, 1, 1, 2, 0x14);
        // bclr x4, x1, x2 -> clear bit 4
        write_r(&mut m, 0x8000_0004, 0x33, 4, 1, 1, 2, 0x24);
        // binv x5, x1, x2 -> invert bit 4
        write_r(&mut m, 0x8000_0008, 0x33, 5, 1, 1, 2, 0x34);
        // bext x6, x1, x2 -> extract bit 4
        write_r(&mut m, 0x8000_000c, 0x33, 6, 5, 1, 2, 0x24);
        // bseti x7, x1, 0 -> set bit 0
        m.write_le::<4>(
            0x8000_0010,
            (0x0a << 26 | 1 << 15 | 1 << 12 | 7 << 7 | 0x13) as u64,
        )
        .unwrap();
        write_i(&mut m, 0x8000_0014, 0x73, 0, 0, 0, 0);

        assert_eq!(h.run(&mut m, 64, 10), Halt::StepLimit);
        assert_eq!(h.regs.get(3), 0x0000_0000_0000_00f0 | (1 << 4));
        assert_eq!(h.regs.get(4), 0x0000_0000_0000_00f0 & !(1 << 4));
        assert_eq!(h.regs.get(5), 0x0000_0000_0000_00f0 ^ (1 << 4));
        assert_eq!(h.regs.get(6), 1); // bit 4 of 0xf0 is 1
        assert_eq!(h.regs.get(7), 0x0000_0000_0000_00f0 | 1);
    }

    #[test]
    fn zbs_single_bit_immediates() {
        let mut h = hart();
        let mut m = mem();
        h.regs.set(1, 0x0000_0000_0000_0001);

        fn enc_zbs_imm(op: u32, f3: u32, funct6: u32, rd: u32, rs1: u32, shamt: u32) -> u32 {
            funct6 << 26 | shamt << 20 | rs1 << 15 | f3 << 12 | rd << 7 | op
        }

        // bseti x2, x1, 5: set bit 5
        m.write_le::<4>(0x8000_0000, enc_zbs_imm(0x13, 1, 0x0a, 2, 1, 5).into())
            .unwrap();
        // bclri x3, x1, 0: clear bit 0
        m.write_le::<4>(0x8000_0004, enc_zbs_imm(0x13, 1, 0x12, 3, 1, 0).into())
            .unwrap();
        // binvi x4, x1, 1: invert bit 1 -> 3
        m.write_le::<4>(0x8000_0008, enc_zbs_imm(0x13, 1, 0x1a, 4, 1, 1).into())
            .unwrap();
        // bexti x5, x1, 0: extract bit 0 -> 1
        m.write_le::<4>(0x8000_000c, enc_zbs_imm(0x13, 5, 0x12, 5, 1, 0).into())
            .unwrap();
        write_i(&mut m, 0x8000_0010, 0x73, 0, 0, 0, 0);

        assert_eq!(h.run(&mut m, 64, 10), Halt::StepLimit);
        assert_eq!(h.regs.get(2), 0x21);
        assert_eq!(h.regs.get(3), 0);
        assert_eq!(h.regs.get(4), 3);
        assert_eq!(h.regs.get(5), 1);
    }

    #[test]
    fn zba_unsigned_word_ops_zero_extend_low_word() {
        let mut h = hart();
        let mut m = mem();
        h.regs.set(1, 0xffff_0000_0000_1234); // low word 0x1234
        h.regs.set(2, 10);
        // add.uw x3, x1, x2 -> 10 + 0x1234
        write_r(&mut m, 0x8000_0000, 0x3b, 3, 0, 1, 2, 0x04);
        // sh1add.uw x4, x1, x2 -> 10 + (0x1234 << 1)
        write_r(&mut m, 0x8000_0004, 0x3b, 4, 2, 1, 2, 0x10);
        // sh2add.uw x5, x1, x2 -> 10 + (0x1234 << 2)
        write_r(&mut m, 0x8000_0008, 0x3b, 5, 4, 1, 2, 0x10);
        // sh3add.uw x6, x1, x2 -> 10 + (0x1234 << 3)
        write_r(&mut m, 0x8000_000c, 0x3b, 6, 6, 1, 2, 0x10);
        // slli.uw x7, x1, 4 -> 0x1234 << 4
        write_slli_uw(&mut m, 0x8000_0010, 7, 1, 4);
        write_i(&mut m, 0x8000_0014, 0x73, 0, 0, 0, 0);

        assert_eq!(h.run(&mut m, 64, 10), Halt::StepLimit);
        assert_eq!(h.regs.get(3), 0x1234 + 10);
        assert_eq!(h.regs.get(4), (0x1234 << 1) + 10);
        assert_eq!(h.regs.get(5), (0x1234 << 2) + 10);
        assert_eq!(h.regs.get(6), (0x1234 << 3) + 10);
        assert_eq!(h.regs.get(7), 0x1234 << 4);
    }

    #[test]
    fn zbb_basic_bit_manipulation() {
        let mut h = hart();
        let mut m = mem();
        // Inputs: x1/x2 for logical-with-negate, x22-x31 hold constants.
        h.regs.set(1, 0x0f0f);
        h.regs.set(2, 0x00ff);
        h.regs.set(22, 0x0000_0000_0000_8000);
        h.regs.set(23, 0x0f0f_0f0f_0f0f_0f0f);
        h.regs.set(24, 0x0000_0000_0000_00ff);
        h.regs.set(25, 4);
        h.regs.set(26, 0x0102_0304_0506_0708);
        h.regs.set(27, 0x0000_0000_0000_0102);
        h.regs.set(28, 0x80);
        h.regs.set(29, 0x0000_0000_0000_1234);
        h.regs.set(30, 0xffff_ffff_ffff_1234);
        h.regs.set(31, 0x0f0f_0f0f);

        // andn x3, x1, x2 -> 0x0f0f & ~0x00ff = 0x0f00
        write_r(&mut m, 0x8000_0000, 0x33, 3, 7, 1, 2, 0x20);
        // orn x4, x1, x2 -> 0x0f0f | ~0x00ff = 0xffff_ffff_ffff_ff0f
        write_r(&mut m, 0x8000_0004, 0x33, 4, 6, 1, 2, 0x20);
        // xnor x5, x1, x2 -> ~(0x0f0f ^ 0x00ff) = 0xffff_ffff_ffff_f00f
        write_r(&mut m, 0x8000_0008, 0x33, 5, 4, 1, 2, 0x20);

        // clz x6, x22 -> 48
        write_i(&mut m, 0x8000_000c, 0x13, 6, 1, 22, 0x600);
        // ctz x7, x22 -> 15
        write_i(&mut m, 0x8000_0010, 0x13, 7, 1, 22, 0x601);

        // cpop x8, x23 -> 32
        write_i(&mut m, 0x8000_0014, 0x13, 8, 1, 23, 0x602);

        // rol x9, x24, x25 -> 0xff0
        write_r(&mut m, 0x8000_0018, 0x33, 9, 1, 24, 25, 0x30);
        // ror x10, x9, x25 -> 0xff
        write_r(&mut m, 0x8000_001c, 0x33, 10, 5, 9, 25, 0x30);
        // rori x11, x9, 4 -> 0xff
        write_i(&mut m, 0x8000_0020, 0x13, 11, 5, 9, 0x604);

        // rev8 x12, x26 -> 0x0807_0605_0403_0201
        write_i(&mut m, 0x8000_0024, 0x13, 12, 5, 26, 0x6b8);

        // orc.b x13, x27 -> 0xffff
        write_i(&mut m, 0x8000_0028, 0x13, 13, 5, 27, 0x287);

        // sext.b x14, x28 -> 0xffff...ff80
        write_i(&mut m, 0x8000_002c, 0x13, 14, 1, 28, 0x604);
        // sext.h x15, x22 -> 0xffff...8000
        write_i(&mut m, 0x8000_0030, 0x13, 15, 1, 22, 0x605);
        // zext.h x16, x22 -> 0x8000
        write_r(&mut m, 0x8000_0034, 0x3b, 16, 4, 22, 0, 0x04);

        // min x17, x30, x29 (signed: x30 negative, x29 positive) -> x30 (negative)
        write_r(&mut m, 0x8000_0038, 0x33, 17, 4, 30, 29, 0x05);
        // max x18, x30, x29 -> x29
        write_r(&mut m, 0x8000_003c, 0x33, 18, 6, 30, 29, 0x05);
        // minu x19, x30, x29 (unsigned: x30 huge) -> x29
        write_r(&mut m, 0x8000_0040, 0x33, 19, 5, 30, 29, 0x05);
        // maxu x20, x30, x29 -> x30
        write_r(&mut m, 0x8000_0044, 0x33, 20, 7, 30, 29, 0x05);

        // clzw x21, x22 -> 16
        write_i(&mut m, 0x8000_0048, 0x1b, 21, 1, 22, 0x600);
        // ctzw x22, x22 -> 15
        write_i(&mut m, 0x8000_004c, 0x1b, 22, 1, 22, 0x601);
        // cpopw x23, x31 -> 16
        write_i(&mut m, 0x8000_0050, 0x1b, 23, 1, 31, 0x602);

        write_i(&mut m, 0x8000_0054, 0x73, 0, 0, 0, 0);

        assert_eq!(h.run(&mut m, 64, 40), Halt::StepLimit);
        assert_eq!(h.regs.get(3), 0x0f00, "andn");
        assert_eq!(h.regs.get(4), 0xffff_ffff_ffff_ff0f, "orn");
        assert_eq!(h.regs.get(5), !(0x0f0f ^ 0x00ff), "xnor");
        assert_eq!(h.regs.get(6), 48, "clz");
        assert_eq!(h.regs.get(7), 15, "ctz");
        assert_eq!(h.regs.get(8), 32, "cpop");
        assert_eq!(h.regs.get(9), 0xff0, "rol");
        assert_eq!(h.regs.get(10), 0xff, "ror");
        assert_eq!(h.regs.get(11), 0xff, "rori");
        assert_eq!(h.regs.get(12), 0x0807_0605_0403_0201, "rev8");
        assert_eq!(h.regs.get(13), 0xffff, "orc.b");
        assert_eq!(h.regs.get(14), 0xffff_ffff_ffff_ff80, "sext.b");
        assert_eq!(h.regs.get(15), 0xffff_ffff_ffff_8000, "sext.h");
        assert_eq!(h.regs.get(16), 0x8000, "zext.h");
        assert_eq!(h.regs.get(17), 0xffff_ffff_ffff_1234, "min");
        assert_eq!(h.regs.get(18), 0x0000_0000_0000_1234, "max");
        assert_eq!(h.regs.get(19), 0x0000_0000_0000_1234, "minu");
        assert_eq!(h.regs.get(20), 0xffff_ffff_ffff_1234, "maxu");
        assert_eq!(h.regs.get(21), 16, "clzw");
        assert_eq!(h.regs.get(22), 15, "ctzw");
        assert_eq!(h.regs.get(23), 16, "cpopw");
    }

    #[test]
    fn zbb_word_rotates() {
        let mut h = hart();
        let mut m = mem();
        h.regs.set(24, 0x7fff_ffff);
        h.regs.set(25, 1);
        // rolw x26, x24, x25 -> 0xffff_fffe, sign-extended
        write_r(&mut m, 0x8000_0000, 0x3b, 26, 1, 24, 25, 0x30);
        // rorw x27, x26, x25 -> 0x7fff_ffff
        write_r(&mut m, 0x8000_0004, 0x3b, 27, 5, 26, 25, 0x30);
        // roriw x28, x27, 1 -> 0xbfff_ffff, sign-extended
        write_i(&mut m, 0x8000_0008, 0x1b, 28, 5, 27, 0x601);

        write_i(&mut m, 0x8000_000c, 0x73, 0, 0, 0, 0);

        assert_eq!(h.run(&mut m, 64, 10), Halt::StepLimit);
        assert_eq!(
            h.regs.get(26),
            0xffff_ffff_ffff_fffe,
            "rolw sign-extends negative result"
        );
        assert_eq!(h.regs.get(27), 0x7fff_ffff, "rorw round-trips to positive");
        assert_eq!(
            h.regs.get(28),
            0xffff_ffff_bfff_ffff,
            "roriw sign-extends negative result"
        );
    }

    #[test]
    fn amocas_doubleword_swaps_when_expected() {
        let mut h = hart();
        let mut m = mem();
        m.add(Region::new(0x9000_0000, 0x1000));
        m.write_le::<8>(0x9000_0000, 0x0123_4567_89ab_cdef).unwrap();
        h.regs.set(10, 0x9000_0000);
        h.regs.set(11, 0x0123_4567_89ab_cdef);
        h.regs.set(12, 0xfedc_ba98_7654_3210);

        // amocas.d x11, x12, 0(x10)
        write_amo(&mut m, 0x8000_0000, 11, 3, 10, 12, 0x05);
        write_i(&mut m, 0x8000_0004, 0x73, 0, 0, 0, 0);

        assert_eq!(h.run(&mut m, 64, 10), Halt::StepLimit);
        assert_eq!(h.regs.get(11), 0x0123_4567_89ab_cdef);
        assert_eq!(m.read_le::<8>(0x9000_0000).unwrap(), 0xfedc_ba98_7654_3210);
    }

    #[test]
    fn uart_mmio_writes_collect_output() {
        use crate::device::Uart;
        use crate::mem::{Device, DeviceKind};
        let mut h = hart();
        let mut m = mem();
        m.add_device(Device::new(
            0x1000_0000,
            0x100,
            DeviceKind::Uart(Uart::new()),
        ));

        // lui x1, 0x10000  -> x1 = 0x1000_0000
        write_u(&mut m, 0x8000_0000, 0x37, 1, 0x10000);
        // addi x2, x0, 'H'
        write_i(&mut m, 0x8000_0004, 0x13, 2, 0, 0, b'H' as i64);
        // sb x2, 0(x1)
        write_s(&mut m, 0x8000_0008, 0x23, 0, 1, 2, 0);
        // addi x2, x0, 'i'
        write_i(&mut m, 0x8000_000c, 0x13, 2, 0, 0, b'i' as i64);
        // sb x2, 0(x1)
        write_s(&mut m, 0x8000_0010, 0x23, 0, 1, 2, 0);
        write_i(&mut m, 0x8000_0014, 0x73, 0, 0, 0, 0);

        assert_eq!(h.run(&mut m, 64, 20), Halt::StepLimit);
        let out = m.uart().map(|u| u.output.clone()).unwrap_or_default();
        assert_eq!(out, b"Hi");
    }

    #[test]
    fn mret_restores_pc_and_privilege() {
        let mut h = hart();
        let mut m = mem();
        h.csr.mepc = 0x8000_0ff0;
        h.csr.set_mode(3);
        h.csr.mstatus = (1u64 << 7) | (1u64 << 3) | (3u64 << 11);
        // mret at 0x8000_0000; target is a no-op lui x0,0
        write_priv(&mut m, 0x8000_0000, 0x18, 0x02);
        write_u(&mut m, 0x8000_0ff0, 0x37, 0, 0);

        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.regs.pc, 0x8000_0ff0);
        assert_eq!(h.csr.mode(), 3);
        assert_eq!((h.csr.mstatus >> 3) & 1, 1, "MIE restored from MPIE");
        assert_eq!((h.csr.mstatus >> 11) & 0x3, 0, "MPP reset to U");
    }

    #[test]
    fn sret_restores_pc_and_privilege() {
        let mut h = hart();
        let mut m = mem();
        h.csr.sepc = 0x8000_1000;
        h.csr.set_mode(1);
        h.csr.mstatus = (1u64 << 5) | (1u64 << 1) | (1u64 << 8);
        // sret
        write_priv(&mut m, 0x8000_0000, 0x08, 0x02);

        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.regs.pc, 0x8000_1000);
        assert_eq!(h.csr.mode(), 1);
        assert_eq!((h.csr.mstatus >> 1) & 1, 1, "SIE restored from SPIE");
        assert_eq!((h.csr.mstatus >> 8) & 1, 0, "SPP reset to U");
    }

    #[test]
    fn timer_interrupt_delivers_to_mtvec() {
        use crate::device::Clint;
        use crate::mem::{Device, DeviceKind};
        let mut h = hart();
        let mut m = mem();
        m.add_device(Device::new(
            0x0200_0000,
            0x10000,
            DeviceKind::Clint(Clint::new(1)),
        ));
        if let Some(c) = m.clint_mut() {
            c.mtimecmp[0] = 0;
        }
        h.csr.mie = 1u64 << 7;
        h.csr.mstatus = (1u64 << 3) | (3u64 << 11);
        h.csr.mtvec = 0x7000_0000;
        // lui x0, 0 at 0x8000_0000 (no-op), second step sees MTIP and traps
        write_u(&mut m, 0x8000_0000, 0x37, 0, 0);

        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.csr.mcause, 0x8000_0000_0000_0007);
        assert_eq!(h.regs.pc, 0x7000_0000);
    }

    #[test]
    fn m_mode_software_interrupt_uses_mtvec() {
        use crate::device::Clint;
        use crate::mem::{Device, DeviceKind};
        let mut h = hart();
        let mut m = mem();
        m.add_device(Device::new(
            0x0200_0000,
            0x10000,
            DeviceKind::Clint(Clint::new(1)),
        ));
        if let Some(c) = m.clint_mut() {
            c.msip[0] = 1;
        }
        h.csr.mie = 1u64 << 3;
        h.csr.mstatus = (1u64 << 3) | (3u64 << 11);
        h.csr.mtvec = 0x7000_0000;
        // no-op to be interrupted
        write_u(&mut m, 0x8000_0000, 0x37, 0, 0);

        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.csr.mcause, 0x8000_0000_0000_0003);
        assert_eq!(h.regs.pc, 0x7000_0000);
    }

    #[test]
    fn s_mode_software_interrupt_uses_stvec() {
        use crate::device::Clint;
        use crate::mem::{Device, DeviceKind};
        let mut h = hart();
        let mut m = mem();
        m.add_device(Device::new(
            0x0200_0000,
            0x10000,
            DeviceKind::Clint(Clint::new(1)),
        ));
        if let Some(c) = m.clint_mut() {
            c.msip[0] = 1;
        }
        h.csr.set_mode(1);
        h.csr.mideleg = 1 << 1;
        h.csr.mie = 1u64 << 1;
        h.csr.mstatus = (1u64 << 1) | (1u64 << 8);
        h.csr.stvec = 0x6000_0000;
        // no-op to be interrupted
        write_u(&mut m, 0x8000_0000, 0x37, 0, 0);

        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.csr.scause, 0x8000_0000_0000_0001);
        assert_eq!(h.regs.pc, 0x6000_0000);
    }

    #[test]
    fn s_mode_timer_interrupt_uses_stvec() {
        use crate::device::Clint;
        use crate::mem::{Device, DeviceKind};
        let mut h = hart();
        let mut m = mem();
        m.add_device(Device::new(
            0x0200_0000,
            0x10000,
            DeviceKind::Clint(Clint::new(1)),
        ));
        if let Some(c) = m.clint_mut() {
            c.mtimecmp[0] = 0;
        }
        h.csr.set_mode(1);
        h.csr.mideleg = 1 << 5;
        h.csr.mie = 1u64 << 5;
        h.csr.mstatus = (1u64 << 1) | (1u64 << 8); // SIE=1, SPP=S
        h.csr.stvec = 0x6000_0000;
        // no-op to be interrupted
        write_u(&mut m, 0x8000_0000, 0x37, 0, 0);

        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.csr.scause, 0x8000_0000_0000_0005);
        assert_eq!(h.regs.pc, 0x6000_0000);
        assert_eq!(h.csr.mode(), 1);
    }

    #[test]
    fn external_interrupt_delivers_to_mtvec() {
        use crate::device::Plic;
        use crate::mem::{Device, DeviceKind};
        let mut h = hart();
        let mut m = mem();
        m.add_device(Device::new(
            0x0c00_0000,
            0x40_0000,
            DeviceKind::Plic(Plic::new(30, 16)),
        ));
        if let Some(p) = m.plic_mut() {
            p.priority[5] = 1;
            p.enable[0] = 1 << 5;
            p.pending = 1 << 5;
        }
        h.csr.mie = 1u64 << 11;
        h.csr.mstatus = (1u64 << 3) | (3u64 << 11);
        h.csr.mtvec = 0x7000_0000;
        // no-op to be interrupted
        write_u(&mut m, 0x8000_0000, 0x37, 0, 0);

        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.csr.mcause, 0x8000_0000_0000_0011);
        assert_eq!(h.regs.pc, 0x7000_0000);
    }

    #[test]
    fn trap_sets_mtval_for_illegal_and_fault() {
        let mut h = hart();
        let mut m = mem();
        // Illegal instruction word 0x00000000.
        m.write_le::<4>(0x8000_0000, 0x0000_0000).unwrap();
        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.csr.mcause, 2);
        assert_eq!(h.csr.mtval, 0);

        // Load from unmapped address 0x9000_0000.
        h.regs.pc = 0x8000_0004;
        m.write_le::<4>(0x8000_0004, 0x0000_3003).unwrap(); // lb x0, 0(x0)
                                                            // lb uses rs1=0, imm=0, so address is 0 (which has no region -> out of bounds).
        h.csr.mtvec = 0x7000_0000;
        h.csr.mcause = 0;
        h.csr.mtval = 0;
        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.csr.mcause, 5);
        assert_eq!(h.csr.mtval, 0);
    }

    #[test]
    fn medeleg_routes_u_ecall_to_smode_trap() {
        let mut h = hart();
        let mut m = mem();
        // ecall at 0x8000_0000 while in U mode.
        m.write_le::<4>(0x8000_0000, 0x0000_0073).unwrap();
        h.csr.set_mode(0);
        h.csr.medeleg = 1 << 8; // U-mode ecall
        h.csr.stvec = 0x6000_0000;
        h.csr.mstatus = 1u64 << 1; // SIE = 1, so SPIE captures it

        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.csr.mode(), 1);
        assert_eq!(h.regs.pc, 0x6000_0000);
        assert_eq!(h.csr.scause, 8);
        assert_eq!(h.csr.sepc, 0x8000_0000);
        assert_eq!(h.csr.stval, 0);
        // SPP = U (0), SPIE = previous SIE (1), SIE = 0.
        assert_eq!((h.csr.mstatus >> 8) & 1, 0);
        assert_eq!((h.csr.mstatus >> 5) & 1, 1);
        assert_eq!((h.csr.mstatus >> 1) & 1, 0);
    }

    #[test]
    fn sv39_one_gigabyte_page_maps_vaddr_to_paddr() {
        let mut h = hart();
        let mut m = mem();
        // Page table at 0x9000_0000. PTE 0 maps VPN 0 -> a 1 GiB leaf at paddr 0x8000_0000.
        // ppn = 0x8000_0000 >> 12 = 0x80000 (lower 18 bits zero for a 1 GiB page).
        let pte = (0x80000u64 << 10) | 0xF;
        let pt_base = 0x9000_0000u64;
        let pt_ppn = pt_base >> 12;
        m.add(Region::new(pt_base, 0x1000));
        m.write_le::<8>(pt_base, pte).unwrap();

        // Program at 0x8000_0000: lui x0, 0
        m.write_le::<4>(0x8000_0000, 0x0000_0037).unwrap();

        h.csr.satp = (8u64 << 60) | pt_ppn;
        h.regs.pc = 0;

        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.regs.pc, 4);
    }

    #[test]
    fn sv32_four_megabyte_page_fetches_and_advances_pc() {
        let mut h = Hart::new(0x8000_0000);
        h.csr.mtvec = 0x7000_0000;
        h.mmu = Mmu::sv32();
        let mut m = PhysMem::new();
        m.add(Region::new(0x8000_0000, 0x1000));

        // Page table at 0x9000_0000 with a 4 MiB level-1 leaf.
        let pt_base = 0x9000_0000u64;
        m.add(Region::new(pt_base, 0x1000));
        let ppn = 0x8000_0000u64 >> 12;
        let pte = (ppn << 10) | 0xF;
        m.write_le::<4>(pt_base, pte).unwrap();

        // Program at 0x8000_0000: lui x0, 0
        m.write_le::<4>(0x8000_0000, 0x0000_0037).unwrap();

        h.csr.satp = (1u64 << 31) | (pt_base >> 12);
        h.regs.pc = 0;

        assert_eq!(h.step(&mut m, 32), None);
        assert_eq!(h.regs.pc, 4);
    }

    #[test]
    fn sv48_one_gigabyte_page_fetches_and_advances_pc() {
        let mut h = Hart::new(0x8000_0000);
        h.csr.mtvec = 0x7000_0000;
        h.mmu = Mmu::sv48();
        let mut m = PhysMem::new();
        m.add(Region::new(0x8000_0000, 0x1000));

        // Root at 0x9000_0000, l2 table at 0x9000_1000, 1 GiB leaf at l2[0].
        let pt_base = 0x9000_0000u64;
        let l2_base = 0x9000_1000u64;
        m.add(Region::new(pt_base, 0x2000));
        let l2_ppn = l2_base >> 12;
        m.write_le::<8>(pt_base, (l2_ppn << 10) | 0x1).unwrap();

        let ppn = 0x8000_0000u64 >> 12;
        m.write_le::<8>(l2_base, (ppn << 10) | 0xF).unwrap();

        // Program at 0x8000_0000: lui x0, 0
        m.write_le::<4>(0x8000_0000, 0x0000_0037).unwrap();

        h.csr.satp = (9u64 << 60) | (pt_base >> 12);
        h.regs.pc = 0;

        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.regs.pc, 4);
    }

    #[test]
    fn f_load_store_and_move_preserve_bits() {
        let mut h = hart();
        let mut m = mem();
        h.csr.mstatus |= 1 << 13; // FS = Initial
        m.add(Region::new(0x9000_0000, 0x1000));
        h.regs.set(10, 0x9000_0000);
        m.write_le::<4>(0x9000_0000, 0x4040_0000).unwrap(); // 3.0

        // flw f1, 0(x10)
        write_fp_i(&mut m, 0x8000_0000, 1, 10, 0);
        // fsw f1, 4(x10)
        write_fp_s(&mut m, 0x8000_0004, 10, 1, 4);
        // fmv.x.w x1, f1
        write_fp_r(&mut m, 0x8000_0008, 1, 0, 1, 0, 0x38);
        // fmv.w.x f2, x1
        write_fp_r(&mut m, 0x8000_000c, 2, 0, 1, 0, 0x3c);

        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.fregs.get_f32(1), 3.0f32);
        assert_eq!(m.read_le::<4>(0x9000_0004).unwrap(), 0x4040_0000);
        assert_eq!(h.regs.get(1), 0x0000_0000_4040_0000);
        assert_eq!(h.fregs.get_s(2), 0x4040_0000);
    }

    #[test]
    fn f_basic_arithmetic_and_fma() {
        let mut h = hart();
        let mut m = mem();
        h.csr.mstatus |= 1 << 13;
        h.regs.set(1, 0x4040_0000); // 3.0
        h.regs.set(2, 0x4000_0000); // 2.0

        // fmv.w.x f1, x1; fmv.w.x f2, x2
        write_fp_r(&mut m, 0x8000_0000, 1, 0, 1, 0, 0x3c);
        write_fp_r(&mut m, 0x8000_0004, 2, 0, 2, 0, 0x3c);
        // fadd.s f3, f1, f2
        write_fp_r(&mut m, 0x8000_0008, 3, 0, 1, 2, 0x00);
        // fsub.s f4, f3, f2
        write_fp_r(&mut m, 0x8000_000c, 4, 0, 3, 2, 0x04);
        // fmul.s f5, f3, f2
        write_fp_r(&mut m, 0x8000_0010, 5, 0, 3, 2, 0x08);
        // fdiv.s f6, f5, f2
        write_fp_r(&mut m, 0x8000_0014, 6, 0, 5, 2, 0x0c);
        // fsqrt.s f7, f5
        write_fp_r(&mut m, 0x8000_0018, 7, 0, 5, 0, 0x2c);

        for _ in 0..8 {
            assert_eq!(h.step(&mut m, 64), None);
        }

        assert!((h.fregs.get_f32(3) - 5.0).abs() < 1e-6);
        assert!((h.fregs.get_f32(4) - 3.0).abs() < 1e-6);
        assert!((h.fregs.get_f32(5) - 10.0).abs() < 1e-6);
        assert!((h.fregs.get_f32(6) - 5.0).abs() < 1e-6);
        assert!((h.fregs.get_f32(7) - 10.0f32.sqrt()).abs() < 1e-6);
    }

    #[test]
    fn f_fma_computes_mul_add() {
        let mut h = hart();
        let mut m = mem();
        h.csr.mstatus |= 1 << 13;
        h.regs.set(1, 0x4040_0000); // 3.0
        h.regs.set(2, 0x4000_0000); // 2.0

        write_fp_r(&mut m, 0x8000_0000, 1, 0, 1, 0, 0x3c);
        write_fp_r(&mut m, 0x8000_0004, 2, 0, 2, 0, 0x3c);
        // fmadd.s f3, f1, f2, f1 -> 3*2+3 = 9
        write_fp_r4(&mut m, 0x8000_0008, 0x43, 3, 1, 2, 1, 0, 0);
        // fmsub.s f4, f1, f2, f1 -> 3*2-3 = 3
        write_fp_r4(&mut m, 0x8000_000c, 0x47, 4, 1, 2, 1, 0, 0);

        for _ in 0..4 {
            assert_eq!(h.step(&mut m, 64), None);
        }

        assert!((h.fregs.get_f32(3) - 9.0).abs() < 1e-6);
        assert!((h.fregs.get_f32(4) - 3.0).abs() < 1e-6);
    }

    #[test]
    fn f_sign_injection_min_max_and_compare() {
        let mut h = hart();
        let mut m = mem();
        h.csr.mstatus |= 1 << 13;
        h.regs.set(1, 0x4040_0000); // 3.0
        h.regs.set(2, 0xc000_0000u64); // -2.0

        write_fp_r(&mut m, 0x8000_0000, 1, 0, 1, 0, 0x3c);
        write_fp_r(&mut m, 0x8000_0004, 2, 0, 2, 0, 0x3c);
        // fsgnj.s f3, f1, f2 -> -3.0
        write_fp_r(&mut m, 0x8000_0008, 3, 0x0, 1, 2, 0x10);
        // fmin.s f4, f1, f2 -> -2.0
        write_fp_r(&mut m, 0x8000_000c, 4, 0, 1, 2, 0x14);
        // fmax.s f5, f1, f2 -> 3.0
        write_fp_r(&mut m, 0x8000_0010, 5, 0x1, 1, 2, 0x14);
        // feq.s x3, f1, f2 -> 0
        write_fp_r(&mut m, 0x8000_0014, 3, 0x2, 1, 2, 0x50);
        // flt.s x4, f2, f1 -> 1
        write_fp_r(&mut m, 0x8000_0018, 4, 0x1, 2, 1, 0x50);

        for _ in 0..7 {
            assert_eq!(h.step(&mut m, 64), None);
        }

        assert!((h.fregs.get_f32(3) + 3.0).abs() < 1e-6);
        assert!((h.fregs.get_f32(4) + 2.0).abs() < 1e-6);
        assert!((h.fregs.get_f32(5) - 3.0).abs() < 1e-6);
        assert_eq!(h.regs.get(3), 0);
        assert_eq!(h.regs.get(4), 1);
    }

    #[test]
    fn f_classify_converts_and_csr_round_trip() {
        let mut h = hart();
        let mut m = mem();
        h.csr.mstatus |= 1 << 13;
        h.regs.set(1, 0x4040_0000); // 3.0
        h.regs.set(2, 5);

        write_fp_r(&mut m, 0x8000_0000, 1, 0, 1, 0, 0x3c);
        // fcvt.s.w f2, x2 -> 5.0
        write_fp_r(&mut m, 0x8000_0004, 2, 0, 2, 0, 0x34);
        // fcvt.w.s x3, f2 -> 5
        write_fp_r(&mut m, 0x8000_0008, 3, 0, 2, 0, 0x30);
        // fclass.s x4, f1 -> 1<<6 (positive normal)
        write_fp_r(&mut m, 0x8000_000c, 4, 0x1, 1, 0x0, 0x38);
        // csrrw x5, fcsr, x2 -> old fcsr, then fcsr = (5 & 0xff) (frm=0, fflags=5)
        write_csr(&mut m, 0x8000_0010, 5, 2, 0x003);

        for _ in 0..5 {
            assert_eq!(h.step(&mut m, 64), None);
        }

        assert!((h.fregs.get_f32(2) - 5.0).abs() < 1e-6);
        assert_eq!(h.regs.get(3), 5);
        assert_eq!(h.regs.get(4), 1 << 6);
        assert_eq!(h.csr.fcsr(), 5);
        assert_eq!(h.regs.get(5), 0); // initial fcsr is 0
    }

    #[test]
    fn f_commit_records_carry_fp_writes() {
        let mut h = hart();
        let mut m = mem();
        h.csr.mstatus |= 1 << 13;
        h.regs.set(1, 0x4040_0000);

        write_fp_r(&mut m, 0x8000_0000, 1, 0, 1, 0, 0x3c);
        // fmv.x.w x2, f1
        write_fp_r(&mut m, 0x8000_0004, 2, 0, 1, 0, 0x38);

        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.records.last().unwrap().frd_addr, 1);
        assert_eq!(h.records.last().unwrap().frd_wdata, nan_box(0x4040_0000));

        assert_eq!(h.step(&mut m, 64), None);
        let r = h.records.last().unwrap();
        assert_eq!(r.rd_addr, 2);
        assert_eq!(r.rd_wdata, 0x0000_0000_4040_0000);
        assert_eq!(r.frd_addr, 0);
    }

    #[test]
    fn d_load_store_and_move_preserve_bits() {
        let mut h = hart();
        let mut m = mem();
        h.csr.mstatus |= 1 << 13;
        m.add(Region::new(0x9000_0000, 0x1000));
        h.regs.set(10, 0x9000_0000);
        m.write_le::<8>(0x9000_0000, 0x4008_0000_0000_0000).unwrap(); // 3.0

        // fld f1, 0(x10)
        write_fp_d_i(&mut m, 0x8000_0000, 1, 10, 0);
        // fsd f1, 8(x10)
        write_fp_d_s(&mut m, 0x8000_0004, 10, 1, 8);
        // fmv.x.d x1, f1
        write_fp_r(&mut m, 0x8000_0008, 1, 0, 1, 0, 0x39);
        // fmv.d.x f2, x1
        write_fp_r(&mut m, 0x8000_000c, 2, 0, 1, 0, 0x3d);

        for _ in 0..4 {
            assert_eq!(h.step(&mut m, 64), None);
        }

        assert!((h.fregs.get_f64(1) - 3.0).abs() < 1e-12);
        assert_eq!(m.read_le::<8>(0x9000_0008).unwrap(), 0x4008_0000_0000_0000);
        assert_eq!(h.regs.get(1), 0x4008_0000_0000_0000);
        assert_eq!(h.fregs.get_d(2), 0x4008_0000_0000_0000);
    }

    #[test]
    fn d_basic_arithmetic_fma_convert_compare() {
        let mut h = hart();
        let mut m = mem();
        h.csr.mstatus |= 1 << 13;
        h.regs.set(1, 0x4008_0000_0000_0000); // 3.0
        h.regs.set(2, 0xc004_0000_0000_0000); // -2.5

        // fmv.d.x f1, x1; fmv.d.x f2, x2
        write_fp_r(&mut m, 0x8000_0000, 1, 0, 1, 0, 0x3d);
        write_fp_r(&mut m, 0x8000_0004, 2, 0, 2, 0, 0x3d);
        // fadd.d f3, f1, f2
        write_fp_r(&mut m, 0x8000_0008, 3, 0, 1, 2, 0x01);
        // fsub.d f4, f3, f2
        write_fp_r(&mut m, 0x8000_000c, 4, 0, 3, 2, 0x05);
        // fmul.d f5, f3, f2
        write_fp_r(&mut m, 0x8000_0010, 5, 0, 3, 2, 0x09);
        // fdiv.d f6, f5, f2
        write_fp_r(&mut m, 0x8000_0014, 6, 0, 5, 2, 0x0d);
        // fsqrt.d f7, f1
        write_fp_r(&mut m, 0x8000_0018, 7, 0, 1, 0, 0x2d);
        // fmadd.d f8, f1, f2, f1
        write_fp_r4(&mut m, 0x8000_001c, 0x43, 8, 1, 2, 1, 0, 1);
        // fmsub.d f9, f1, f2, f1
        write_fp_r4(&mut m, 0x8000_0020, 0x47, 9, 1, 2, 1, 0, 1);
        // fcvt.s.d f10, f1
        write_fp_r(&mut m, 0x8000_0024, 10, 0, 1, 1, 0x20);
        // fcvt.d.s f11, f10
        write_fp_r(&mut m, 0x8000_0028, 11, 0, 10, 0, 0x21);
        // fcvt.w.d x3, f1
        write_fp_r(&mut m, 0x8000_002c, 3, 0, 1, 0, 0x31);
        // fcvt.d.w f12, x3
        write_fp_r(&mut m, 0x8000_0030, 12, 0, 3, 0, 0x35);
        // fsgnj.d f13, f1, f2
        write_fp_r(&mut m, 0x8000_0034, 13, 0, 1, 2, 0x11);
        // fmin.d f14, f1, f2
        write_fp_r(&mut m, 0x8000_0038, 14, 0, 1, 2, 0x15);
        // fmax.d f15, f1, f2
        write_fp_r(&mut m, 0x8000_003c, 15, 1, 1, 2, 0x15);
        // feq.d x4, f1, f2
        write_fp_r(&mut m, 0x8000_0040, 4, 2, 1, 2, 0x51);
        // flt.d x5, f2, f1
        write_fp_r(&mut m, 0x8000_0044, 5, 1, 2, 1, 0x51);
        // fle.d x6, f1, f1
        write_fp_r(&mut m, 0x8000_0048, 6, 0, 1, 1, 0x51);
        // fclass.d x7, f1
        write_fp_r(&mut m, 0x8000_004c, 7, 1, 1, 0, 0x39);
        // fmv.x.d x8, f1
        write_fp_r(&mut m, 0x8000_0050, 8, 0, 1, 0, 0x39);

        for _ in 0..21 {
            assert_eq!(h.step(&mut m, 64), None);
        }

        assert!((h.fregs.get_f64(3) - 0.5).abs() < 1e-12);
        assert!((h.fregs.get_f64(4) - 3.0).abs() < 1e-12);
        assert!((h.fregs.get_f64(5) - (-1.25)).abs() < 1e-12);
        assert!((h.fregs.get_f64(6) - 0.5).abs() < 1e-12);
        assert!((h.fregs.get_f64(7) - 3.0f64.sqrt()).abs() < 1e-12);
        assert!((h.fregs.get_f64(8) - (-4.5)).abs() < 1e-12);
        assert!((h.fregs.get_f64(9) - (-10.5)).abs() < 1e-12);
        assert!((h.fregs.get_f32(10) - 3.0).abs() < 1e-6);
        assert!((h.fregs.get_f64(11) - 3.0).abs() < 1e-12);
        assert!((h.fregs.get_f64(12) - 3.0).abs() < 1e-12);
        assert!((h.fregs.get_f64(13) - (-3.0)).abs() < 1e-12);
        assert!((h.fregs.get_f64(14) - (-2.5)).abs() < 1e-12);
        assert!((h.fregs.get_f64(15) - 3.0).abs() < 1e-12);
        assert_eq!(h.regs.get(3), 3);
        assert_eq!(h.regs.get(4), 0);
        assert_eq!(h.regs.get(5), 1);
        assert_eq!(h.regs.get(6), 1);
        assert_eq!(h.regs.get(7), 1 << 6);
        assert_eq!(h.regs.get(8), 0x4008_0000_0000_0000);
    }

    #[test]
    fn unimplemented_opcodes_trap_with_cause_2() {
        let mut h = hart();
        let mut m = mem();
        m.write_le::<4>(0x8000_0000, 0x0000_0000).unwrap();
        assert_eq!(h.run(&mut m, 64, 10), Halt::StepLimit);
        assert_eq!(h.csr.mcause, 2);
        assert_eq!(h.regs.pc, 0x7000_0000);
    }

    #[test]
    fn f32_arith_flags_and_nan_cases() {
        // Overflow: finite operands producing an infinite result.
        let r = Hart::f32_mul(f32::MAX, 2.0f32, 0x0);
        assert_eq!(r.value, f32::INFINITY.to_bits());
        assert_eq!(r.flags & Hart::FFLAG_OF, Hart::FFLAG_OF);
        assert_eq!(r.flags & Hart::FFLAG_NX, Hart::FFLAG_NX);

        // Divide by zero.
        let r = Hart::f32_div(1.0f32, 0.0f32, 0x0);
        assert_eq!(r.value, f32::INFINITY.to_bits());
        assert_eq!(r.flags & Hart::FFLAG_DZ, Hart::FFLAG_DZ);

        // 0/0 is invalid.
        let r = Hart::f32_div(0.0f32, 0.0f32, 0x0);
        assert_eq!(r.value, Hart::F32_CANONICAL_NAN);
        assert_eq!(r.flags & Hart::FFLAG_NV, Hart::FFLAG_NV);

        // inf - inf is invalid.
        let r = Hart::f32_sub(f32::INFINITY, f32::INFINITY, 0x0);
        assert_eq!(r.value, Hart::F32_CANONICAL_NAN);
        assert_eq!(r.flags & Hart::FFLAG_NV, Hart::FFLAG_NV);

        // inf * 0 is invalid.
        let r = Hart::f32_mul(f32::INFINITY, 0.0f32, 0x0);
        assert_eq!(r.value, Hart::F32_CANONICAL_NAN);
        assert_eq!(r.flags & Hart::FFLAG_NV, Hart::FFLAG_NV);

        // sqrt of a negative number is invalid.
        let r = Hart::f32_sqrt(-1.0f32, 0x0);
        assert_eq!(r.value, Hart::F32_CANONICAL_NAN);
        assert_eq!(r.flags & Hart::FFLAG_NV, Hart::FFLAG_NV);

        // min/max: quiet NaN with a number returns the number and no NV.
        let qnan = f32::from_bits(0x7fc0_0000);
        let (v, nv) = Hart::f32_minmax(qnan, 1.0f32, false);
        assert_eq!(v, 1.0f32);
        assert!(!nv);

        // min/max: signaling NaN with a number returns the number and NV.
        let snan = f32::from_bits(0x7f80_0001);
        let (v, nv) = Hart::f32_minmax(snan, 1.0f32, false);
        assert_eq!(v, 1.0f32);
        assert!(nv);

        // min/max of two quiet NaNs returns the canonical quiet NaN and no NV.
        let (v, nv) = Hart::f32_minmax(qnan, qnan, false);
        assert_eq!(v.to_bits(), Hart::F32_CANONICAL_NAN);
        assert!(!nv);
    }

    #[test]
    fn f64_arith_flags_and_fma_cases() {
        // Overflow.
        let r = Hart::f64_mul(f64::MAX, 2.0f64, 0x0);
        assert_eq!(r.value, f64::INFINITY.to_bits());
        assert_eq!(r.flags & Hart::FFLAG_OF, Hart::FFLAG_OF);
        assert_eq!(r.flags & Hart::FFLAG_NX, Hart::FFLAG_NX);

        // Divide by zero.
        let r = Hart::f64_div(1.0f64, 0.0f64, 0x0);
        assert_eq!(r.value, f64::INFINITY.to_bits());
        assert_eq!(r.flags & Hart::FFLAG_DZ, Hart::FFLAG_DZ);

        // 0/0 is invalid.
        let r = Hart::f64_div(0.0f64, 0.0f64, 0x0);
        assert_eq!(r.value, Hart::F64_CANONICAL_NAN);
        assert_eq!(r.flags & Hart::FFLAG_NV, Hart::FFLAG_NV);

        // inf - inf is invalid.
        let r = Hart::f64_sub(f64::INFINITY, f64::INFINITY, 0x0);
        assert_eq!(r.value, Hart::F64_CANONICAL_NAN);
        assert_eq!(r.flags & Hart::FFLAG_NV, Hart::FFLAG_NV);

        // Exact fma: 2*3 + 4 = 10.
        let r = Hart::f64_fma(2.0f64, 3.0f64, 4.0f64, 0x0, false, false);
        assert_eq!(r.value, 10.0f64.to_bits());
        assert_eq!(r.flags, 0);

        // Negated-product fma: -(2*3) + 4 = -2.
        let r = Hart::f64_fma(2.0f64, 3.0f64, 4.0f64, 0x0, true, false);
        assert_eq!(r.value, (-2.0f64).to_bits());
        assert_eq!(r.flags, 0);

        // Negated-summand fma: 2*3 + (-4) = 2.
        let r = Hart::f64_fma(2.0f64, 3.0f64, 4.0f64, 0x0, false, true);
        assert_eq!(r.value, 2.0f64.to_bits());
        assert_eq!(r.flags, 0);

        // Both negated: -(2*3) + (-4) = -10.
        let r = Hart::f64_fma(2.0f64, 3.0f64, 4.0f64, 0x0, true, true);
        assert_eq!(r.value, (-10.0f64).to_bits());
        assert_eq!(r.flags, 0);

        // FMA overflow: MAX * 2 + 0 -> inf.
        let r = Hart::f64_fma(f64::MAX, 2.0f64, 0.0f64, 0x0, false, false);
        assert_eq!(r.value, f64::INFINITY.to_bits());
        assert_eq!(r.flags & Hart::FFLAG_OF, Hart::FFLAG_OF);
        assert_eq!(r.flags & Hart::FFLAG_NX, Hart::FFLAG_NX);

        // FMA invalid: inf * 0 + 1.
        let r = Hart::f64_fma(f64::INFINITY, 0.0f64, 1.0f64, 0x0, false, false);
        assert_eq!(r.value, Hart::F64_CANONICAL_NAN);
        assert_eq!(r.flags & Hart::FFLAG_NV, Hart::FFLAG_NV);

        // FMA inf - inf.
        let r = Hart::f64_fma(f64::INFINITY, 1.0f64, f64::NEG_INFINITY, 0x0, false, false);
        assert_eq!(r.value, Hart::F64_CANONICAL_NAN);
        assert_eq!(r.flags & Hart::FFLAG_NV, Hart::FFLAG_NV);

        // min/max with quiet and signaling NaNs.
        let qnan = f64::from_bits(0x7ff8_0000_0000_0000);
        let snan = f64::from_bits(0x7ff0_0000_0000_0001);
        let (v, nv) = Hart::f64_minmax(qnan, 1.0f64, false);
        assert_eq!(v, 1.0f64);
        assert!(!nv);
        let (v, nv) = Hart::f64_minmax(snan, 1.0f64, false);
        assert_eq!(v, 1.0f64);
        assert!(nv);
        let (v, nv) = Hart::f64_minmax(qnan, qnan, false);
        assert_eq!(v.to_bits(), Hart::F64_CANONICAL_NAN);
        assert!(!nv);
    }

    #[test]
    fn f64_directed_rounding_sets_nx_and_picks_the_right_bracket() {
        // 1.0 + 2^-53 is exactly the tie between 1.0 and next_up(1.0).
        let ulp = Hart::f64_next_up(1.0f64) - 1.0f64;
        let half_ulp = ulp / 2.0;

        // RNE: tie to even -> 1.0, inexact (NX).
        let r = Hart::f64_add(1.0f64, half_ulp, 0x0);
        assert_eq!(r.value, 1.0f64.to_bits());
        assert_eq!(r.flags & Hart::FFLAG_NX, Hart::FFLAG_NX);

        // RUP: toward +inf -> next_up, inexact.
        let r = Hart::f64_add(1.0f64, half_ulp, 0x3);
        assert_eq!(r.value, Hart::f64_next_up(1.0f64).to_bits());
        assert_eq!(r.flags & Hart::FFLAG_NX, Hart::FFLAG_NX);

        // RTZ: toward zero -> 1.0, inexact.
        let r = Hart::f64_add(1.0f64, half_ulp, 0x1);
        assert_eq!(r.value, 1.0f64.to_bits());
        assert_eq!(r.flags & Hart::FFLAG_NX, Hart::FFLAG_NX);

        // A value strictly between 1.0 and the tie: all except RUP round to 1.0.
        let tiny = half_ulp / 2.0;
        let r = Hart::f64_add(1.0f64, tiny, 0x3);
        assert_eq!(r.value, Hart::f64_next_up(1.0f64).to_bits());
        assert_eq!(r.flags & Hart::FFLAG_NX, Hart::FFLAG_NX);

        // Negative tie: RDN/RMM keep the value away from zero, RUP/RTZ move toward zero.
        let r = Hart::f64_sub(-1.0f64, half_ulp, 0x2); // RDN
        assert_eq!(r.value, (-Hart::f64_next_up(1.0f64)).to_bits());
        assert_eq!(r.flags & Hart::FFLAG_NX, Hart::FFLAG_NX);

        let r = Hart::f64_sub(-1.0f64, half_ulp, 0x3); // RUP
        assert_eq!(r.value, (-1.0f64).to_bits());
        assert_eq!(r.flags & Hart::FFLAG_NX, Hart::FFLAG_NX);

        // Multiplication with a non-tie inexact product.
        let a = Hart::f64_next_up(1.0f64); // 1 + ulp
        let r = Hart::f64_mul(a, a, 0x2); // RDN
                                          // a*a = 1 + 2*ulp + ulp^2; the next f64 down from 1+2*ulp is 1+ulp.
        assert_eq!(
            r.value,
            Hart::f64_next_up(Hart::f64_next_up(1.0f64)).to_bits()
        );
        assert_eq!(r.flags & Hart::FFLAG_NX, Hart::FFLAG_NX);
    }

    #[test]
    fn fp_conversion_rounding_and_nan_cases() {
        // f64 -> f32 overflow.
        let r = Hart::round_f64_to_f32(f64::MAX, 0x0, false);
        assert_eq!(r.value, f32::INFINITY.to_bits());
        assert_eq!(r.flags & Hart::FFLAG_OF, Hart::FFLAG_OF);
        assert_eq!(r.flags & Hart::FFLAG_NX, Hart::FFLAG_NX);

        // f64 -> f32 of a source inf does not overflow when allow_infinite is true.
        let r = Hart::round_f64_to_f32(f64::INFINITY, 0x0, true);
        assert_eq!(r.value, f32::INFINITY.to_bits());
        assert_eq!(r.flags, 0);

        // f64 -> f32 of a quiet NaN canonicalises and raises no NV.
        let qnan = f64::from_bits(0x7ff8_0000_0000_0000);
        let r = Hart::round_f64_to_f32(qnan, 0x0, true);
        assert_eq!(r.value, Hart::F32_CANONICAL_NAN);
        assert_eq!(r.flags & Hart::FFLAG_NV, 0);

        // f64 -> f32 of a signaling NaN canonicalises and raises NV.
        let snan = f64::from_bits(0x7ff0_0000_0000_0001);
        let r = Hart::round_f64_to_f32(snan, 0x0, true);
        assert_eq!(r.value, Hart::F32_CANONICAL_NAN);
        assert_eq!(r.flags & Hart::FFLAG_NV, Hart::FFLAG_NV);

        // f32 -> f64 widening is exact.
        let r = Hart::round_f32_to_f64(1.5f32);
        assert_eq!(r.value, 1.5f64.to_bits());
        assert_eq!(r.flags, 0);

        // f32 -> f64 of a quiet NaN canonicalises.
        let qnan = f32::from_bits(0x7fc0_0000);
        let r = Hart::round_f32_to_f64(qnan);
        assert_eq!(r.value, Hart::F64_CANONICAL_NAN);
        assert_eq!(r.flags, 0);

        // f32 -> f64 of a signaling NaN canonicalises and raises NV.
        let snan = f32::from_bits(0x7f80_0001);
        let r = Hart::round_f32_to_f64(snan);
        assert_eq!(r.value, Hart::F64_CANONICAL_NAN);
        assert_eq!(r.flags & Hart::FFLAG_NV, Hart::FFLAG_NV);

        // Integer to f32 conversion: small integer is exact.
        let r = Hart::int_to_f32(42, 0x0);
        assert_eq!(r.value, 42.0f32.to_bits());
        assert_eq!(r.flags, 0);

        // f32 -> unsigned 32-bit integer with RTZ is inexact.
        let r = Hart::f32_to_int(f64::from(42.9f32), 0x1, 32, true);
        assert_eq!(r.value, 42);
        assert_eq!(r.flags, Hart::FFLAG_NX);

        // f64 -> signed 64-bit integer overflow saturates and raises NV.
        let r = Hart::f64_to_int(f64::MAX, 0x0, 64, false);
        assert_eq!(r.value, i64::MAX as u64);
        assert_eq!(r.flags & Hart::FFLAG_NV, Hart::FFLAG_NV);
    }

    #[test]
    fn ai_queue_enq_poll_qfence_execute() {
        use crate::device::AiIsland;
        use crate::mem::{Device, DeviceKind};
        let mut h = hart();
        let mut m = mem();
        let mut ai_island = AiIsland::new();
        let ai_model = g6q_core::model::AiIslandModel {
            config: g6q_core::model::AiIslandConfig {
                queue_depth: 8,
                ..Default::default()
            },
            ..Default::default()
        };
        ai_island.set_ai_model(&ai_model);
        m.add_device(Device::new(
            0x3000_0000,
            0x1000,
            DeviceKind::AiIsland(ai_island),
        ));

        h.ai_instr_set = Some(g6q_core::model::AiInstrSet {
            opcode_custom2: 0x5B,
            mask_f7f3op: 0xFE00707F,
            match_enq: 0x0000505B,
            match_poll: 0x0200505B,
            match_qfence: 0x0400505B,
            ..Default::default()
        });
        h.ai_model = Some(ai_model);

        // x10 = 0x8000_0000 (descriptor pointer)
        h.regs.set(10, 0x8000_0000);
        // ai.enq x5, x10 -> rd=5, rs1=10: (10<<15)|(5<<12)|(5<<7)|0x5B
        m.write_le::<4>(0x8000_0000, (10 << 15) | (5 << 12) | (5 << 7) | 0x5B)
            .unwrap();
        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.regs.get(5), 0);

        // ai.qfence
        m.write_le::<4>(0x8000_0004, (2 << 25) | (5 << 12) | 0x5B)
            .unwrap();
        assert_eq!(h.step(&mut m, 64), None);

        // ai.poll x6, x5 -> rd=6, rs1=5: f7=1
        m.write_le::<4>(
            0x8000_0008,
            (1 << 25) | (5 << 15) | (5 << 12) | (6 << 7) | 0x5B,
        )
        .unwrap();
        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.regs.get(6), 0);

        if let Some(ai) = m.ai_island_mut() {
            let events = ai.drain_events();
            assert_eq!(events.len(), 1);
            assert_eq!(events[0].descriptor_addr, 0x8000_0000);
            assert!(events[0].done);
        }
    }

    fn dma_guest_fixture(c_ptr: u64, done_ptr: u64, op: u16) -> (Hart, PhysMem) {
        use crate::device::AiIsland;
        use crate::mem::{Device, DeviceKind, Region};
        let mut h = hart();
        let mut m = mem();
        let mut model = crate::device::tests::model_with_control_surface();
        model.desc_layout.statuses.insert("ST_BAD_PTR".into(), 0x55);
        let mut ai = AiIsland::new();
        ai.set_ai_model(&model);
        ai.version = model.desc_layout.version.unwrap() as u16;
        ai.op = op;
        ai.m = 2;
        ai.n = 2;
        ai.k = 2;
        ai.ld_ab = 2 | (2 << 16);
        ai.ptr_a = 0x9000_0000;
        ai.ptr_b = 0x9000_1000;
        ai.ptr_c = c_ptr;
        ai.ptr_done = done_ptr;
        m.add(Region::new(0x9000_0000, 0x4000));
        for offset in 0..4 {
            m.write_le::<1>(ai.ptr_a + offset, offset + 1).unwrap();
            m.write_le::<1>(ai.ptr_b + offset, offset + 5).unwrap();
        }
        for offset in 0..16 {
            m.write_le::<1>(0x9000_2000 + offset, 0xa5).unwrap();
        }
        for (name, field) in &model.desc_layout.fields {
            let value = match name.as_str() {
                "version" => ai.version as u64,
                "op" => op as u64,
                "m" | "n" | "k" => 2,
                "ld_ab" => ai.ld_ab as u64,
                "ptr_a" => ai.ptr_a,
                "ptr_b" => ai.ptr_b,
                "ptr_c" => c_ptr,
                "ptr_done" => done_ptr,
                _ => 0,
            };
            let addr = 0x9000_0400 + field.offset;
            match field.size {
                2 => m.write_le::<2>(addr, value).unwrap(),
                4 => m.write_le::<4>(addr, value).unwrap(),
                8 => m.write_le::<8>(addr, value).unwrap(),
                _ => panic!("fixture field width"),
            }
        }
        m.add_device(Device::new(0x4000_0000, 0x1000, DeviceKind::AiIsland(ai)));
        h.ai_model = Some(model);
        h.ai_instr_set = Some(g6q_core::model::AiInstrSet {
            opcode_custom2: 0x5b,
            mask_f7f3op: 0xfe00707f,
            match_enq: 0x0000505b,
            match_poll: 0x0200505b,
            match_qfence: 0x0400505b,
            ..Default::default()
        });
        (h, m)
    }

    fn overlay_dma_device(m: &mut PhysMem, base: u64) {
        use crate::mem::{Device, DeviceKind};
        let saved = m.snapshot();
        let island = m.ai_island().unwrap().clone();
        let mut restored = PhysMem::new();
        restored.add_device(Device::new(
            0x4000_0000,
            0x1000,
            DeviceKind::AiIsland(island),
        ));
        restored.add_device(Device::new(
            base,
            1,
            DeviceKind::Uart(crate::device::Uart::default()),
        ));
        restored.restore(&saved);
        *m = restored;
    }

    fn ring_dma_guest(h: &mut Hart, m: &mut PhysMem) {
        let config = &h.ai_model.as_ref().unwrap().config;
        m.write_le::<4>(0x4000_0000 + config.reg_offset("ctl").unwrap(), 3)
            .unwrap();
        m.write_le::<4>(0x4000_0000 + config.reg_offset("doorbell").unwrap(), 1)
            .unwrap();
        m.write_le::<4>(0x8000_0000, 0x13).unwrap();
        assert_eq!(h.step(m, 64), None);
    }

    #[test]
    fn pending_guest_dma_bad_c_reports_failure_without_partial_c() {
        for c_ptr in [
            0x9000_2001,
            0xa000_0000,
            0x9000_3ff8,
            0x4000_0140,
            u64::MAX - 3,
            0x9000_2000,
        ] {
            let (mut h, mut m) = dma_guest_fixture(c_ptr, 0x9000_3000, 1);
            if c_ptr == 0x9000_2000 {
                overlay_dma_device(&mut m, c_ptr + 7);
            }
            ring_dma_guest(&mut h, &mut m);
            let ai = m.ai_island().unwrap();
            assert_eq!(ai.last_status, 0x55, "C={c_ptr:#x}");
            assert_eq!(ai.status, 0x55);
            assert_eq!(ai.ticket, 1);
            assert_eq!(ai.events.len(), 1);
            assert_eq!(ai.events[0].status, 0x55);
            assert!(ai.events[0].done);
            assert_eq!(m.read_le::<8>(0x9000_3000).unwrap(), 1 | (0x55 << 32));
            let ram = m
                .snapshot()
                .into_iter()
                .find(|r| r.0 == 0x9000_0000)
                .unwrap()
                .2;
            assert_eq!(&ram[0x2000..0x2010], &[0xa5; 16]);
            assert_eq!(&ram[0x3ff8..0x4000], &[0; 8]);
            h.run_pending_ai_job(&mut m);
            assert_eq!(m.ai_island().unwrap().ticket, 1);
        }
    }

    #[test]
    fn pending_guest_dma_bad_completion_rejects_gemm_and_skipped_ops() {
        for op in [1, 3] {
            for ptr in [
                0x9000_3001,
                0xa000_0000,
                0x9000_3ffc,
                0x4000_0000,
                u64::MAX - 3,
                0x9000_3000,
            ] {
                let (mut h, mut m) = dma_guest_fixture(0x9000_2000, ptr, op);
                if ptr == 0x9000_3000 {
                    overlay_dma_device(&mut m, ptr + 7);
                }
                ring_dma_guest(&mut h, &mut m);
                let ai = m.ai_island().unwrap();
                assert_eq!(ai.status, 0x55, "done={ptr:#x}, op={op}");
                assert_eq!(ai.events.len(), 1);
                assert_eq!(ai.events[0].ptr_done, ptr);
                assert_eq!(ai.events[0].status, 0x55);
                let ram = m
                    .snapshot()
                    .into_iter()
                    .find(|r| r.0 == 0x9000_0000)
                    .unwrap()
                    .2;
                assert_eq!(&ram[0x2000..0x2010], &[0xa5; 16]);
            }
        }
    }

    #[test]
    fn queue_dma_failure_is_visible_and_sticky_in_guest_poll() {
        for ptr in [
            0x9000_3001,
            0xa000_0000,
            0x9000_3ffc,
            0x4000_0000,
            0x9000_3000,
        ] {
            let (mut h, mut m) = dma_guest_fixture(0x9000_2000, ptr, 3);
            if ptr == 0x9000_3000 {
                overlay_dma_device(&mut m, ptr + 7);
            }
            h.regs.set(10, 0x9000_0400);
            let enq = (10 << 15) | (5 << 12) | (5 << 7) | 0x5b;
            let fence = (2 << 25) | (5 << 12) | 0x5b;
            let poll = (1 << 25) | (5 << 15) | (5 << 12) | (6 << 7) | 0x5b;
            for (i, word) in [enq, fence, poll, fence, poll].iter().enumerate() {
                m.write_le::<4>(0x8000_0000 + i as u64 * 4, *word).unwrap();
            }
            for _ in 0..5 {
                assert_eq!(h.step(&mut m, 64), None);
            }
            assert_eq!(h.regs.get(6), 0x55 << 32, "done={ptr:#x}");
            let ai = m.ai_island_mut().unwrap();
            assert_eq!(ai.queue_poll(0), Some(0x55 << 32));
            assert_eq!(ai.events.len(), 1);
            assert_eq!(ai.events[0].status, 0x55);
            assert_eq!(ai.events[0].ptr_done, ptr);
            assert_eq!(ai.events[0].descriptor_addr, 0x9000_0400);
            assert_eq!(ai.queues[0].tail, 1);
        }
    }

    #[test]
    fn dma_write_boundaries_revalidate_and_do_not_double_complete() {
        let (h, mut m) = dma_guest_fixture(0x9000_2000, 0x9000_3000, 3);
        assert!(Hart::apply_ai_c_writes(&mut m, &[(0x9000_2000, 7), (0xa000_0000, 8)]).is_err());
        assert_eq!(m.read_le::<4>(0x9000_2000).unwrap(), 0xa5a5a5a5);
        let model = h.ai_model.as_ref().unwrap();
        let ev = crate::device::AiIsland::read_descriptor_event(&m, 0x9000_0400, 0, model).unwrap();
        let (ptr, word) = {
            let ai = m.ai_island_mut().unwrap();
            ai.wr_cpl_en = true;
            ai.complete_pending_job(ev, ai.codes.ok).unwrap()
        };
        overlay_dma_device(&mut m, ptr + 7);
        assert!(Hart::write_ai_completion(&mut m, ptr, word).is_err());
        let ai = m.ai_island_mut().unwrap();
        ai.fail_pending_dma();
        ai.fail_pending_dma();
        assert_eq!(ai.status, 0x55);
        assert_eq!(ai.last_status, 0x55);
        assert_eq!(ai.ticket, 1);
        assert_eq!(ai.events.len(), 1);
        assert_eq!(ai.events[0].status, 0x55);
        assert_eq!(ai.events[0].ptr_done, ptr);
        assert_eq!(ai.completion_word(), 1 | (0x55 << 32));
    }

    #[test]
    fn guest_poll_reports_a_completion_mapping_lost_after_fence() {
        let (mut h, mut m) = dma_guest_fixture(0x9000_2000, 0x9000_3000, 3);
        h.regs.set(10, 0x9000_0400);
        let words = [
            (10 << 15) | (5 << 12) | (5 << 7) | 0x5b,
            (2 << 25) | (5 << 12) | 0x5b,
            (1 << 25) | (5 << 15) | (5 << 12) | (6 << 7) | 0x5b,
        ];
        for (i, word) in words.iter().enumerate() {
            m.write_le::<4>(0x8000_0000 + i as u64 * 4, *word).unwrap();
        }
        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(m.ai_island().unwrap().events[0].status, 0);
        overlay_dma_device(&mut m, 0x9000_3007);
        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.regs.get(6), 0x55 << 32);
        assert_eq!(m.ai_island().unwrap().events[0].status, 0x55);
    }

    #[test]
    fn ai_enq_reads_descriptor_and_qfence_writes_completion() {
        use crate::device::AiIsland;
        use crate::mem::{Device, DeviceKind, Region};

        let mut h = hart();
        let mut m = mem();
        let mut ai_island = AiIsland::new();
        let ai_model = crate::device::tests::model_with_layout();
        ai_island.set_ai_model(&ai_model);
        m.add_device(Device::new(
            0x3000_0000,
            0x1000,
            DeviceKind::AiIsland(ai_island),
        ));

        h.ai_instr_set = Some(g6q_core::model::AiInstrSet {
            opcode_custom2: 0x5B,
            mask_f7f3op: 0xFE00707F,
            match_enq: 0x0000505B,
            match_poll: 0x0200505B,
            match_qfence: 0x0400505B,
            ..Default::default()
        });
        h.ai_model = Some(ai_model);

        // Descriptor at 0x9000_0000, completion sink at 0xa000_0000.
        let desc_addr = 0x9000_0000u64;
        let done_addr = 0xa000_0000u64;
        m.add(Region::new(desc_addr, 0x1000));
        m.add(Region::new(done_addr, 0x1000));

        // Pack a descriptor using the ingested layout.
        let model = &h.ai_model.as_ref().unwrap().desc_layout;
        for (name, field) in &model.fields {
            let addr = desc_addr + field.offset;
            let value = match name.as_str() {
                "version" => 1u64,
                "op" => 1,
                "flags" => 0x0000_0100, // dtype = 1
                "m" => 4,
                "n" => 4,
                "k" => 4,
                "ptr_a" => 0x9000_1000,
                "ptr_b" => 0x9000_2000,
                "ptr_c" => 0x9000_3000,
                "ptr_done" => done_addr,
                _ => 0,
            };
            match field.size {
                2 => m.write_le::<2>(addr, value).unwrap(),
                4 => m.write_le::<4>(addr, value).unwrap(),
                8 => m.write_le::<8>(addr, value).unwrap(),
                _ => {}
            }
        }

        // Point x10 at the descriptor.
        h.regs.set(10, desc_addr);

        // ai.enq x5, x10 -> rd=5, rs1=10: (10<<15)|(5<<12)|(5<<7)|0x5B
        m.write_le::<4>(0x8000_0000, (10 << 15) | (5 << 12) | (5 << 7) | 0x5B)
            .unwrap();
        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.regs.get(5), 0);

        // ai.qfence
        m.write_le::<4>(0x8000_0004, (2 << 25) | (5 << 12) | 0x5B)
            .unwrap();
        assert_eq!(h.step(&mut m, 64), None);

        // The island should have written the completion word to ptr_done.
        let word = m.read_le::<8>(done_addr).unwrap();
        let ticket = word & ((1u64 << 32) - 1);
        let status = (word >> 32) & 0xffff;
        assert_eq!(ticket, 0);
        assert_eq!(status, 0);

        // The tensor event carries the descriptor's fields, not the MMIO shadow state.
        if let Some(ai) = m.ai_island_mut() {
            let events = ai.drain_events();
            assert_eq!(events.len(), 1);
            assert_eq!(events[0].descriptor_addr, desc_addr);
            assert_eq!(events[0].op, 1);
            assert_eq!(events[0].dtype, 1);
            assert_eq!(events[0].ptr_done, done_addr);
            assert!(events[0].done);
        }
    }

    #[test]
    fn ai_poll_writes_completion_word_to_ptr_done() {
        use crate::device::AiIsland;
        use crate::mem::{Device, DeviceKind, Region};

        let mut h = hart();
        let mut m = mem();
        let mut ai_island = AiIsland::new();
        let ai_model = crate::device::tests::model_with_layout();
        ai_island.set_ai_model(&ai_model);
        m.add_device(Device::new(
            0x3000_0000,
            0x1000,
            DeviceKind::AiIsland(ai_island),
        ));

        h.ai_instr_set = Some(g6q_core::model::AiInstrSet {
            opcode_custom2: 0x5B,
            mask_f7f3op: 0xFE00707F,
            match_enq: 0x0000505B,
            match_poll: 0x0200505B,
            match_qfence: 0x0400505B,
            ..Default::default()
        });
        h.ai_model = Some(ai_model);

        let desc_addr = 0x9000_0000u64;
        let done_addr = 0xa000_0000u64;
        m.add(Region::new(desc_addr, 0x1000));
        m.add(Region::new(done_addr, 0x1000));

        // Pack a descriptor using the ingested layout.
        let model = &h.ai_model.as_ref().unwrap().desc_layout;
        for (name, field) in &model.fields {
            let addr = desc_addr + field.offset;
            let value = match name.as_str() {
                "version" => 1u64,
                "op" => 1,
                "flags" => 0x0000_0100,
                "m" => 4,
                "n" => 4,
                "k" => 4,
                "ptr_a" => 0x9000_1000,
                "ptr_b" => 0x9000_2000,
                "ptr_c" => 0x9000_3000,
                "ptr_done" => done_addr,
                _ => 0,
            };
            match field.size {
                2 => m.write_le::<2>(addr, value).unwrap(),
                4 => m.write_le::<4>(addr, value).unwrap(),
                8 => m.write_le::<8>(addr, value).unwrap(),
                _ => {}
            }
        }

        h.regs.set(10, desc_addr);

        // ai.enq x5, x10
        m.write_le::<4>(0x8000_0000, (10 << 15) | (5 << 12) | (5 << 7) | 0x5B)
            .unwrap();
        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.regs.get(5), 0);

        // ai.qfence to mark the entry done.
        m.write_le::<4>(0x8000_0004, (2 << 25) | (5 << 12) | 0x5B)
            .unwrap();
        assert_eq!(h.step(&mut m, 64), None);

        // Overwrite the completion word at ptr_done with a dummy sentinel so the
        // poll write is observable.
        m.write_le::<8>(done_addr, 0xdead_beef_dead_beef).unwrap();

        // ai.poll x6, x5 -> rd=6, rs1=5
        m.write_le::<4>(
            0x8000_0008,
            (1 << 25) | (5 << 15) | (5 << 12) | (6 << 7) | 0x5B,
        )
        .unwrap();
        assert_eq!(h.step(&mut m, 64), None);

        // The poll should have re-written the completion word.
        let word = m.read_le::<8>(done_addr).unwrap();
        let ticket = word & ((1u64 << 32) - 1);
        let status = (word >> 32) & 0xffff;
        assert_eq!(ticket, 0);
        assert_eq!(status, 0);
        assert_eq!(h.regs.get(6), word);
    }

    /// The whole in-guest path, driven only through MMIO stores and loads.
    ///
    /// This is the shape a UIO-backed runtime uses: no custom instruction, no host-side
    /// help — enable, fill the descriptor latch, ring the bell, read the status, read `C`.
    /// It is the gate that separates "the completion word appeared" from "the island
    /// computed something", which every earlier island smoke could not tell apart.
    #[test]
    fn a_guest_can_drive_a_gemm_entirely_through_the_published_mmio_window() {
        use crate::device::AiIsland;
        use crate::mem::{Device, DeviceKind, Region};

        let mut h = hart();
        let mut m = mem();
        let ai_model = crate::device::tests::model_with_control_surface();
        let mut ai_island = AiIsland::new();
        ai_island.set_ai_model(&ai_model);
        const ISLAND: u64 = 0x4000_0000;
        m.add_device(Device::new(ISLAND, 0x1000, DeviceKind::AiIsland(ai_island)));
        h.ai_model = Some(ai_model.clone());

        // Operand and result buffers in guest DRAM.
        let (a_ptr, b_ptr, c_ptr, done_ptr) =
            (0x9000_0000u64, 0x9000_1000, 0x9000_2000, 0x9000_3000);
        m.add(Region::new(0x9000_0000, 0x4000));
        // A = [[1, 2], [3, 4]], B = [[5, 6], [7, 8]]  =>  C = [[19, 22], [43, 50]]
        // B is stored k-major (AI-X9), so its bytes are B'[j][t] = B[t][j] = 5, 7, 6, 8.
        for (i, v) in [1i8, 2, 3, 4].iter().enumerate() {
            m.write_le::<1>(a_ptr + i as u64, *v as u8 as u64).unwrap();
        }
        for (i, v) in [5i8, 7, 6, 8].iter().enumerate() {
            m.write_le::<1>(b_ptr + i as u64, *v as u8 as u64).unwrap();
        }

        // Every offset below comes from the model, not from a constant in this test.
        let reg = |n: &str| ISLAND + ai_model.config.reg_offset(n).unwrap();
        let desc = |field: &str| ISLAND + 0x140 + ai_model.desc_layout.offset(field).unwrap();
        let irq_bit = ai_model.desc_layout.flags_layout.unwrap().irq_bit;

        // CTL: enable + completion-word write.
        m.write_le::<4>(reg("ctl"), 0b11).unwrap();

        // Descriptor: version 1, OP_GEMM, 2x2x2, lda = ldb = 2, IRQ requested.
        // The latch window is word-addressed, so `version` and `op` are the two halves of
        // its first 32-bit word rather than two independently writable registers.
        assert_eq!(
            desc("op"),
            desc("version") + 2,
            "op shares word 0 with version"
        );
        m.write_le::<4>(desc("version"), 1 | (1 << 16)).unwrap();
        m.write_le::<4>(desc("flags"), 1u64 << irq_bit).unwrap();
        m.write_le::<4>(desc("m"), 2).unwrap();
        m.write_le::<4>(desc("n"), 2).unwrap();
        m.write_le::<4>(desc("k"), 2).unwrap();
        m.write_le::<4>(desc("ld_ab"), 2 | (2 << 16)).unwrap();
        m.write_le::<8>(desc("ptr_a"), a_ptr).unwrap();
        m.write_le::<8>(desc("ptr_b"), b_ptr).unwrap();
        m.write_le::<8>(desc("ptr_c"), c_ptr).unwrap();
        m.write_le::<8>(desc("ptr_done"), done_ptr).unwrap();

        // Ring the doorbell, then retire one instruction so the island runs.
        m.write_le::<4>(reg("doorbell"), 1).unwrap();
        m.write_le::<4>(0x8000_0000, 0x00000013).unwrap(); // nop
        assert_eq!(h.step(&mut m, 64), None);

        // C is in guest memory, row-major with ldc = n.
        let c = |i: u64| m.read_le::<4>(c_ptr + i * 4).unwrap() as u32 as i32;
        assert_eq!(
            [c(0), c(1), c(2), c(3)],
            [19, 22, 43, 50],
            "the island must actually multiply, not merely complete"
        );

        // The status register reports idle with ST_OK, and the completion word landed.
        assert_eq!(m.read_le::<4>(reg("status")).unwrap(), 0);
        let word = m.read_le::<8>(done_ptr).unwrap();
        let cl = ai_model.desc_layout.completion.unwrap();
        assert_eq!(word >> cl.status_bit_low & 0xffff, 0, "ST_OK");
        assert_eq!(word & 0xffff_ffff, 1, "first ticket");

        // The descriptor asked for an interrupt, so the source is asserted; claiming it
        // through the completion register drops it, which must happen before the PLIC is
        // completed or a level-set re-arms.
        assert!(m.ai_island().unwrap().irq_pending);
        m.write_le::<4>(reg("cpl"), 1).unwrap();
        assert!(!m.ai_island().unwrap().irq_pending);
    }

    #[test]
    fn a_shape_beyond_the_accumulator_tile_completes_with_an_error_and_writes_no_c() {
        use crate::device::AiIsland;
        use crate::mem::{Device, DeviceKind, Region};

        let mut h = hart();
        let mut m = mem();
        let mut ai_model = crate::device::tests::model_with_control_surface();
        // A part whose accumulator tile is 2: a 4-wide request must be refused, and the
        // refusal must come from the model rather than from a limit typed into the device.
        ai_model.config.acc_tile_m = 2;
        ai_model.config.acc_tile_n = 2;
        ai_model.config.acc_tile_k = 2;
        let mut ai_island = AiIsland::new();
        ai_island.set_ai_model(&ai_model);
        const ISLAND: u64 = 0x4000_0000;
        m.add_device(Device::new(ISLAND, 0x1000, DeviceKind::AiIsland(ai_island)));
        h.ai_model = Some(ai_model.clone());

        m.add(Region::new(0x9000_0000, 0x4000));
        let reg = |n: &str| ISLAND + ai_model.config.reg_offset(n).unwrap();
        let desc = |f: &str| ISLAND + 0x140 + ai_model.desc_layout.offset(f).unwrap();

        m.write_le::<4>(reg("ctl"), 0b11).unwrap();
        m.write_le::<4>(desc("version"), 1 | (1 << 16)).unwrap();
        m.write_le::<4>(desc("m"), 4).unwrap();
        m.write_le::<4>(desc("n"), 4).unwrap();
        m.write_le::<4>(desc("k"), 4).unwrap();
        m.write_le::<4>(desc("ld_ab"), 4 | (4 << 16)).unwrap();
        m.write_le::<8>(desc("ptr_a"), 0x9000_0000).unwrap();
        m.write_le::<8>(desc("ptr_b"), 0x9000_1000).unwrap();
        m.write_le::<8>(desc("ptr_c"), 0x9000_2000).unwrap();
        m.write_le::<4>(reg("doorbell"), 1).unwrap();
        m.write_le::<4>(0x8000_0000, 0x00000013).unwrap();
        assert_eq!(h.step(&mut m, 64), None);

        // ST_ERR in the high half, and C untouched.
        assert_eq!(m.read_le::<4>(reg("status")).unwrap(), 1 << 16);
        assert_eq!(m.read_le::<4>(0x9000_2000).unwrap(), 0);
    }

    #[test]
    fn ai_queue_full_and_ticket_sequence() {
        use crate::device::AiIsland;
        use crate::mem::{Device, DeviceKind};
        let mut h = hart();
        let mut m = mem();
        let mut ai_island = AiIsland::new();
        let ai_model = g6q_core::model::AiIslandModel {
            config: g6q_core::model::AiIslandConfig {
                queue_depth: 2,
                ..Default::default()
            },
            ..Default::default()
        };
        ai_island.set_ai_model(&ai_model);
        m.add_device(Device::new(
            0x3000_0000,
            0x1000,
            DeviceKind::AiIsland(ai_island),
        ));

        h.ai_instr_set = Some(g6q_core::model::AiInstrSet {
            opcode_custom2: 0x5B,
            mask_f7f3op: 0xFE00707F,
            match_enq: 0x0000505B,
            match_poll: 0x0200505B,
            match_qfence: 0x0400505B,
            ..Default::default()
        });
        h.ai_model = Some(ai_model);

        // x10 = 0x8000_0000 (descriptor pointer)
        h.regs.set(10, 0x8000_0000);

        // Enqueue two descriptors.
        for i in 0..2 {
            h.regs.set(10, 0x8000_0000 + i as u64 * 0x1000);
            m.write_le::<4>(
                0x8000_0000 + i as u64 * 4,
                (10 << 15) | (5 << 12) | (5 << 7) | 0x5B,
            )
            .unwrap();
            assert_eq!(h.step(&mut m, 64), None);
            assert_eq!(h.regs.get(5), i as u64);
        }

        // Third enqueue should fail (queue full) and return 0.
        m.write_le::<4>(0x8000_0008, (10 << 15) | (5 << 12) | (5 << 7) | 0x5B)
            .unwrap();
        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.regs.get(5), 0);

        if let Some(ai) = m.ai_island_mut() {
            assert_eq!(ai.inflight_total(), 2);
            let events = ai.drain_events();
            assert_eq!(events.len(), 2);

            // Run qfence: all complete.
            m.write_le::<4>(0x8000_000c, (2 << 25) | (5 << 12) | 0x5B)
                .unwrap();
            assert_eq!(h.step(&mut m, 64), None);

            // Poll first ticket.
            h.regs.set(5, 0);
            m.write_le::<4>(
                0x8000_0010,
                (1 << 25) | (5 << 15) | (5 << 12) | (6 << 7) | 0x5B,
            )
            .unwrap();
            assert_eq!(h.step(&mut m, 64), None);
            assert_eq!(h.regs.get(6), 0);

            let counters = g6q_diag::ai_tensor::tensor_counters(&events);
            let by_name: std::collections::BTreeMap<_, _> = counters
                .iter()
                .map(|c| (c.name.as_str(), c.value))
                .collect();
            assert_eq!(by_name["ai.tensor.queue_entries"], 2);
        }
    }

    #[test]
    fn ai_queue_csrs_read_and_write() {
        use crate::device::AiIsland;
        use crate::mem::{Device, DeviceKind};
        let mut h = hart();
        let mut m = mem();
        let mut ai_island = AiIsland::new();
        let mut ai_model = g6q_core::model::AiIslandModel {
            config: g6q_core::model::AiIslandConfig {
                queue_depth: 4,
                ..Default::default()
            },
            ..Default::default()
        };
        ai_model.instr_set = g6q_core::model::AiInstrSet {
            opcode_custom2: 0x5B,
            mask_f7f3op: 0xFE00707F,
            csr_aiqbase: 0x5C0,
            csr_aiqctl: 0x5C1,
            csr_aiqhead: 0x5C2,
            match_enq: 0x0000505B,
            match_poll: 0x0200505B,
            match_qfence: 0x0400505B,
        };
        ai_island.set_ai_model(&ai_model);
        m.add_device(Device::new(
            0x3000_0000,
            0x1000,
            DeviceKind::AiIsland(ai_island),
        ));
        h.ai_instr_set = Some(ai_model.instr_set.clone());
        h.ai_model = Some(ai_model);

        // x10 = base, x11 = ctl, x12 = head
        h.regs.set(10, 0x9000_0000);
        h.regs.set(11, 0x1);
        h.regs.set(12, 7); // will be wrapped to 7 % 4 = 3

        // csrrw x1, aiqbase, x10
        write_csr(&mut m, 0x8000_0000, 1, 10, 0x5C0);
        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.regs.get(1), 0); // old base

        // csrrw x2, aiqctl, x11
        write_csr(&mut m, 0x8000_0004, 2, 11, 0x5C1);
        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.regs.get(2), 0); // old ctl

        // csrrw x3, aiqhead, x12
        write_csr(&mut m, 0x8000_0008, 3, 12, 0x5C2);
        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.regs.get(3), 0); // old head

        // csrrw x4, aiqhead, x0  (read back current head, write zero)
        write_csr(&mut m, 0x8000_000c, 4, 0, 0x5C2);
        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.regs.get(4), 3); // previous head was 7 % 4

        if let Some(ai) = m.ai_island() {
            let q = &ai.queues[ai.ring_for_hart(0)];
            assert_eq!(q.base, 0x9000_0000, "aiqbase");
            assert_eq!(q.ctl, 0x1, "aiqctl");
            assert_eq!(q.head, 0, "aiqhead");
        }
    }
}
