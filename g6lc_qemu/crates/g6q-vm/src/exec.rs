// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Single-hart interpretive execution engine.
//!
//! Q3 starts with the interpreter tier: fetch, decode, execute, record. The record is
//! produced as a `g6q_diag::CommitRecord` so that the same engine can serve B3 and D1
//! from one path.

use g6q_diag::CommitRecord;

use crate::insn::{decode, Insn};
use crate::mem::PhysMem;
use crate::regs::Regs;
use crate::Clock;

/// Why execution stopped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(missing_docs)]
pub enum Halt {
    /// Reached the requested instruction limit.
    StepLimit,
    /// An `ecall` instruction.
    Ecall,
    /// An `ebreak` instruction.
    Ebreak,
    /// An illegal or unimplemented instruction.
    Illegal(u32),
    /// A memory access fault.
    MemFault,
    /// Deterministic time boundary reached without finishing.
    TimeSlice,
}

use crate::csr::Csr;

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
        let w = match mem.read_le::<4>(self.regs.pc) {
            Ok(v) => v as u32,
            Err(_) => return Some(Halt::MemFault),
        };
        let insn = decode(w, xlen as u32);

        // Capture architectural state before execution changes it.
        let pc_rdata = self.regs.pc;
        let rd_addr = self.result_reg(&insn);

        let pc_wdata = match self.execute(insn, mem, xlen) {
            Ok(pc) => pc,
            Err(ExecError::Mem) => return Some(Halt::MemFault),
            Err(ExecError::Halt(h)) => {
                // Record the instruction before reporting the halt.
                self.record(pc_rdata, pc_rdata.wrapping_add(4), w, rd_addr, 0);
                return Some(h);
            }
        };

        self.record(pc_rdata, pc_wdata, w, rd_addr, self.regs.get(rd_addr));
        self.regs.pc = pc_wdata;
        self.instret += 1;
        self.clock.retire(1);
        if let Some(c) = mem.clint_mut() {
            c.tick();
            if c.timer_pending(0) {
                self.csr.mip |= 1u64 << 7;
            } else {
                self.csr.mip &= !(1u64 << 7);
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
            | Insn::Remuw { rd, .. } => rd,
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
            | Insn::AmomaxuD { rd, .. } => rd,
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
                let v = mem.read_sext::<1>(addr).map_err(|_| ExecError::Mem)?;
                self.regs.set(rd, v as u64);
                Ok(nx)
            }
            Insn::Lh { rd, rs1, imm } => {
                let addr = self.regs.get(rs1).wrapping_add(imm as u64);
                let v = mem.read_sext::<2>(addr).map_err(|_| ExecError::Mem)?;
                self.regs.set(rd, v as u64);
                Ok(nx)
            }
            Insn::Lw { rd, rs1, imm } => {
                let addr = self.regs.get(rs1).wrapping_add(imm as u64);
                let v = mem.read_sext::<4>(addr).map_err(|_| ExecError::Mem)?;
                self.regs.set(rd, v as u64);
                Ok(nx)
            }
            Insn::Lbu { rd, rs1, imm } => {
                let addr = self.regs.get(rs1).wrapping_add(imm as u64);
                let v = mem.read_le::<1>(addr).map_err(|_| ExecError::Mem)?;
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Lhu { rd, rs1, imm } => {
                let addr = self.regs.get(rs1).wrapping_add(imm as u64);
                let v = mem.read_le::<2>(addr).map_err(|_| ExecError::Mem)?;
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Lwu { rd, rs1, imm } => {
                let addr = self.regs.get(rs1).wrapping_add(imm as u64);
                let v = mem.read_le::<4>(addr).map_err(|_| ExecError::Mem)?;
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Ld { rd, rs1, imm } => {
                let addr = self.regs.get(rs1).wrapping_add(imm as u64);
                let v = mem.read_le::<8>(addr).map_err(|_| ExecError::Mem)?;
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::Sb { rs1, rs2, imm } => {
                let addr = self.regs.get(rs1).wrapping_add(imm as u64);
                mem.write_le::<1>(addr, self.regs.get(rs2))
                    .map_err(|_| ExecError::Mem)?;
                Ok(nx)
            }
            Insn::Sh { rs1, rs2, imm } => {
                let addr = self.regs.get(rs1).wrapping_add(imm as u64);
                mem.write_le::<2>(addr, self.regs.get(rs2))
                    .map_err(|_| ExecError::Mem)?;
                Ok(nx)
            }
            Insn::Sw { rs1, rs2, imm } => {
                let addr = self.regs.get(rs1).wrapping_add(imm as u64);
                mem.write_le::<4>(addr, self.regs.get(rs2))
                    .map_err(|_| ExecError::Mem)?;
                Ok(nx)
            }
            Insn::Sd { rs1, rs2, imm } => {
                let addr = self.regs.get(rs1).wrapping_add(imm as u64);
                mem.write_le::<8>(addr, self.regs.get(rs2))
                    .map_err(|_| ExecError::Mem)?;
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

            Insn::LrW { rd, rs1, .. } => {
                let addr = self.regs.get(rs1);
                let v = mem.read_sext::<4>(addr).map_err(|_| ExecError::Mem)?;
                self.reservation = Some(addr);
                self.regs.set(rd, v as u64);
                Ok(nx)
            }
            Insn::LrD { rd, rs1, .. } => {
                let addr = self.regs.get(rs1);
                let v = mem.read_le::<8>(addr).map_err(|_| ExecError::Mem)?;
                self.reservation = Some(addr);
                self.regs.set(rd, v);
                Ok(nx)
            }
            Insn::ScW { rd, rs1, rs2, .. } => {
                let addr = self.regs.get(rs1);
                if self.reservation == Some(addr) {
                    mem.write_le::<4>(addr, self.regs.get(rs2))
                        .map_err(|_| ExecError::Mem)?;
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
                    mem.write_le::<8>(addr, self.regs.get(rs2))
                        .map_err(|_| ExecError::Mem)?;
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

            Insn::Fence | Insn::FenceI => Ok(nx),
            Insn::Csrrw { rd, rs1, csr } => {
                let old = self
                    .csr
                    .read(csr)
                    .map_err(|_| ExecError::Halt(Halt::Illegal(0)))?;
                let new = self.regs.get(rs1);
                self.csr
                    .write(csr, new)
                    .map_err(|_| ExecError::Halt(Halt::Illegal(0)))?;
                self.regs.set(rd, old);
                Ok(nx)
            }
            Insn::Csrrs { rd, rs1, csr } => {
                let old = self
                    .csr
                    .read(csr)
                    .map_err(|_| ExecError::Halt(Halt::Illegal(0)))?;
                if rs1 != 0 {
                    self.csr
                        .read_set(csr, self.regs.get(rs1))
                        .map_err(|_| ExecError::Halt(Halt::Illegal(0)))?;
                }
                self.regs.set(rd, old);
                Ok(nx)
            }
            Insn::Csrrc { rd, rs1, csr } => {
                let old = self
                    .csr
                    .read(csr)
                    .map_err(|_| ExecError::Halt(Halt::Illegal(0)))?;
                if rs1 != 0 {
                    self.csr
                        .read_clear(csr, self.regs.get(rs1))
                        .map_err(|_| ExecError::Halt(Halt::Illegal(0)))?;
                }
                self.regs.set(rd, old);
                Ok(nx)
            }
            Insn::Csrrwi { rd, uimm, csr } => {
                let old = self
                    .csr
                    .read(csr)
                    .map_err(|_| ExecError::Halt(Halt::Illegal(0)))?;
                self.csr
                    .write(csr, uimm as u64)
                    .map_err(|_| ExecError::Halt(Halt::Illegal(0)))?;
                self.regs.set(rd, old);
                Ok(nx)
            }
            Insn::Csrrsi { rd, uimm, csr } => {
                let old = self
                    .csr
                    .read(csr)
                    .map_err(|_| ExecError::Halt(Halt::Illegal(0)))?;
                if uimm != 0 {
                    self.csr
                        .read_set(csr, uimm as u64)
                        .map_err(|_| ExecError::Halt(Halt::Illegal(0)))?;
                }
                self.regs.set(rd, old);
                Ok(nx)
            }
            Insn::Csrrci { rd, uimm, csr } => {
                let old = self
                    .csr
                    .read(csr)
                    .map_err(|_| ExecError::Halt(Halt::Illegal(0)))?;
                if uimm != 0 {
                    self.csr
                        .read_clear(csr, uimm as u64)
                        .map_err(|_| ExecError::Halt(Halt::Illegal(0)))?;
                }
                self.regs.set(rd, old);
                Ok(nx)
            }
            Insn::Ecall => Err(ExecError::Halt(Halt::Ecall)),
            Insn::Ebreak => Err(ExecError::Halt(Halt::Ebreak)),
            Insn::Mret => {
                self.mret();
                Ok(self.regs.pc)
            }
            Insn::Sret => {
                self.sret();
                Ok(self.regs.pc)
            }
            Insn::Wfi => Ok(nx),
            Insn::Illegal(w) => Err(ExecError::Halt(Halt::Illegal(w))),
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
            mem.read_le::<4>(addr).map_err(|_| ExecError::Mem)?
        } else {
            mem.read_le::<8>(addr).map_err(|_| ExecError::Mem)?
        };
        let new = op(old, self.regs.get(rs2));
        if N == 4 {
            mem.write_le::<4>(addr, new).map_err(|_| ExecError::Mem)?;
            self.regs.set(rd, old as i32 as i64 as u64);
        } else {
            mem.write_le::<8>(addr, new).map_err(|_| ExecError::Mem)?;
            self.regs.set(rd, old);
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
    Mem,
    Halt(Halt),
}

#[cfg(test)]
#[allow(clippy::precedence, clippy::too_many_arguments)]
mod tests {
    use super::*;
    use crate::mem::{PhysMem, Region};

    fn hart() -> Hart {
        Hart::new(0x8000_0000)
    }

    fn mem() -> PhysMem {
        let mut m = PhysMem::new();
        m.add(Region::new(0x8000_0000, 0x1000));
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

    fn write_r(m: &mut PhysMem, addr: u64, op: u32, rd: u32, f3: u32, rs1: u32, rs2: u32, f7: u32) {
        let w = f7 << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | rd << 7 | op;
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
        if halt != Halt::Ecall {
            for (i, r) in h.records.iter().rev().take(10).rev().enumerate() {
                eprintln!(
                    "{i}: pc={:#x} insn={:#010x} rd={} w={:#x}",
                    r.pc_rdata, r.insn, r.rd_addr, r.rd_wdata
                );
            }
            eprintln!("fault pc = {:#x}", h.regs.pc);
        }
        assert_eq!(halt, Halt::Ecall);
        assert_eq!(h.regs.get(2), 15, "5 + 4 + 3 + 2 + 1 = 15");
        assert_eq!(h.regs.get(3), 15, "loaded value");
        assert_eq!(h.records.len(), 22);
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

        assert_eq!(h.run(&mut m, 64, 20), Halt::Ecall);
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

        assert_eq!(h.run(&mut m, 64, 20), Halt::Ecall);
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

        assert_eq!(h.run(&mut m, 64, 20), Halt::Ecall);
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
        assert_eq!(h.step(&mut m, 64), Some(Halt::MemFault));
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

        assert_eq!(h.run(&mut m, 64, 20), Halt::Ecall);
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

        assert_eq!(h.run(&mut m, 64, 10), Halt::Ecall);
        assert_eq!(h.regs.get(2), -1i64 as u64);
        assert_eq!(h.regs.get(3), u64::MAX);
    }

    fn write_amo(m: &mut PhysMem, addr: u64, rd: u32, f3: u32, rs1: u32, rs2: u32, funct5: u32) {
        let w = (funct5 << 27) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x2f;
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

        assert_eq!(h.run(&mut m, 64, 20), Halt::Ecall);
        assert_eq!(h.regs.get(1), 0);
        assert_eq!(h.regs.get(2), 0);
        assert_eq!(h.regs.get(3), 5);
        assert_eq!(h.regs.get(4), 0);
        assert_eq!(h.regs.get(5), 5);
        assert_eq!(h.regs.get(6), 0);
        assert_eq!(h.regs.get(7), 1);
    }

    #[test]
    fn unimplemented_opcodes_are_illegal() {
        let mut h = hart();
        let mut m = mem();
        m.write_le::<4>(0x8000_0000, 0x0000_0000).unwrap();
        assert_eq!(h.run(&mut m, 64, 10), Halt::Illegal(0));
    }
}
