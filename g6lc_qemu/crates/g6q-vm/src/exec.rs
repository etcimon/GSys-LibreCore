// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Single-hart interpretive execution engine.
//!
//! Q3 starts with the interpreter tier: fetch, decode, execute, record. The record is
//! produced as a `g6q_diag::CommitRecord` so that the same engine can serve B3 and D1
//! from one path.

use g6q_diag::CommitRecord;

use crate::insn::{decode, Insn};
use crate::mem::{MemError, PhysMem};
use crate::regs::Regs;
use crate::Clock;

/// Why execution stopped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(missing_docs)]
pub enum Halt {
    /// Reached the requested instruction limit.
    StepLimit,
}

use crate::csr::Csr;
use crate::mmu;

/// The state of one hart and its progress.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Hart {
    /// Architectural register file.
    pub regs: Regs,
    /// Deterministic clock.
    pub clock: Clock,
    /// Retired-instruction count.
    pub instret: u64,
    /// Records produced so far.
    pub records: Vec<CommitRecord>,
    /// Address reserved by the most recent `lr` on this hart.
    pub reservation: Option<u64>,
    /// Faulting address (or faulting instruction word) for the next trap.
    pub fault_addr: u64,
    /// Control and status registers.
    pub csr: Csr,
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
            csr: Csr::new(hartid),
            ..Self::default()
        }
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

        let w = match mem.read_le::<4>(pc_paddr) {
            Ok(v) => v as u32,
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

        let insn = decode(w, xlen as u32);

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

        self.record(pc_rdata, pc_wdata, w, rd_addr, self.regs.get(rd_addr));
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

        None
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
            | Insn::SlliUw { rd, .. } => rd,
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

    fn execute(&mut self, insn: Insn, mem: &mut PhysMem, xlen: u8) -> Result<u64, ExecError> {
        let nx = self.regs.next_pc();
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
            Insn::Illegal(w) => {
                self.fault_addr = w as u64;
                self.take_trap(2);
                Ok(self.regs.pc)
            }
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
        Ok(self.regs.next_pc())
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
        Ok(self.regs.next_pc())
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
        match mmu::translate(mem, self.csr.satp, vaddr) {
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

    fn record(&mut self, pc_rdata: u64, pc_wdata: u64, insn: u32, rd_addr: u8, rd_wdata: u64) {
        self.records.push(CommitRecord {
            order: self.instret,
            hart: 0,
            pc_rdata,
            pc_wdata,
            insn,
            trap: false,
            rd_addr,
            rd_wdata,
        });
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
    fn compressed_cannot_be_fetched_from_16bit() {
        // This is a 32-bit-only decoder for the bring-up; C extension lands in a later pass.
        // An attempt to fetch a compressed instruction from an odd halfword address is a
        // memory error because the fetch is 4-byte aligned and may read a half-compressed
        // pair. This test documents the bring-up limitation.
        let mut h = hart();
        h.regs.pc = 0x8000_0002;
        let mut m = mem();
        assert_eq!(h.step(&mut m, 64), None);
        assert_eq!(h.csr.mcause, 0);
        assert_eq!(h.regs.pc, 0x7000_0000);
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
    fn unimplemented_opcodes_trap_with_cause_2() {
        let mut h = hart();
        let mut m = mem();
        m.write_le::<4>(0x8000_0000, 0x0000_0000).unwrap();
        assert_eq!(h.run(&mut m, 64, 10), Halt::StepLimit);
        assert_eq!(h.csr.mcause, 2);
        assert_eq!(h.regs.pc, 0x7000_0000);
    }
}
