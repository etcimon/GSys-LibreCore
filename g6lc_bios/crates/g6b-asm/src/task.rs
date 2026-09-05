// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Pinned-hart, cooperative S-mode integer task ABI, lowered through the ASM IR.
//!
//! This is a context-switch primitive, not a guest scheduler. All participants
//! share an address space and `gp`; `tp` remains the OpenSBI hart identity. There
//! is no migration, task TLS, FP/vector context, trap-frame or preemptive ABI.
//! Interrupt handlers must preserve interrupted registers and must not switch
//! tasks. Contexts and stacks must be resident, writable, exclusively owned by
//! the pinned hart, and disjoint from each other and executable code. No memory
//! publication, IPI, runqueue, stack allocation or executable installation is
//! supplied here. The caller must establish those lifetime/access guarantees.

use crate::encode::{A0, A1, CSR_SSTATUS, RA, SP, SSTATUS_SIE, T0, T1, T2, TP, X0};
use crate::{Module, Node, Op, Purpose};

/// Exported symbol in [`task_switch_ir`].
pub const TASK_SWITCH: &str = "g6b_task_switch";
/// Exported symbol in [`task_entry_ir`].
pub const TASK_ENTRY: &str = "g6b_task_entry";
/// Required context and stack alignment, in bytes (both XLENs).
pub const TASK_ALIGN: u64 = 16;
/// Context slots: ra, sp, s0..s11, SIE mask, immutable owner hart.
pub const TASK_WORDS: usize = 16;
/// Architectural register indices in context-slot order, excluding SIE/owner.
pub const TASK_REGISTERS: [u32; 14] = [RA, SP, 8, 9, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27];

/// Validated XLEN-specific little-endian memory layout; no host struct casting.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TaskLayout {
    xlen: u32,
}

/// Initial task entry and stack. All addresses and the argument are guest words.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TaskStart {
    /// Immutable hart identity, compared with `tp` on every switch.
    pub hart_id: u64,
    /// Low address of the exclusively owned downward-growing stack.
    pub stack_base: u64,
    /// Stack extent; a nonzero multiple of 16, with a representable top address.
    pub stack_bytes: u64,
    /// Resolved address of [`TASK_ENTRY`], not the task handler itself.
    pub entry_pc: u64,
    /// Integer ABI `handler(opaque)`; receives `argument` in a0.
    pub handler_pc: u64,
    /// Opaque XLEN-sized argument; zero is allowed.
    pub argument: u64,
    /// Integer ABI `exit(result) -> !`; receives the handler's a0 return value.
    pub exit_pc: u64,
    /// Initial sstatus.SIE; no other sstatus bits are task-owned.
    pub enable_interrupts: bool,
}

impl TaskLayout {
    /// Accept only RV32/RV64, never silently select a different ABI.
    pub fn new(xlen: u32) -> Result<Self, String> {
        match xlen {
            32 | 64 => Ok(Self { xlen }),
            _ => Err(format!("unsupported task XLEN {xlen}")),
        }
    }

    /// Guest XLEN in bits.
    pub fn xlen(self) -> u32 {
        self.xlen
    }

    /// Bytes in one context slot.
    pub fn word_bytes(self) -> usize {
        (self.xlen / 8) as usize
    }

    /// Exact context extent: 64 bytes on RV32, 128 on RV64.
    pub fn size(self) -> usize {
        TASK_WORDS * self.word_bytes()
    }

    /// Byte offset for ra/sp/s0..s11. Other registers are not task-owned.
    pub fn register_offset(self, register: u32) -> Result<usize, String> {
        TASK_REGISTERS
            .iter()
            .position(|r| *r == register)
            .map(|slot| slot * self.word_bytes())
            .ok_or_else(|| format!("x{register} is not in the cooperative context"))
    }

    /// Byte offset of a word containing only the sstatus.SIE mask (0 or 2).
    pub fn sie_offset(self) -> usize {
        14 * self.word_bytes()
    }

    /// Byte offset of the immutable owner hart word (not restored into tp).
    pub fn hart_offset(self) -> usize {
        15 * self.word_bytes()
    }

    fn check_word(self, value: u64) -> Result<(), String> {
        if self.xlen == 32 && value > u64::from(u32::MAX) {
            Err("task value does not fit XLEN".into())
        } else {
            Ok(())
        }
    }

    fn check_address(self, address: u64, align: u64) -> Result<(), String> {
        self.check_word(address)?;
        if address == 0 || address % align != 0 {
            return Err(format!(
                "task address must be nonzero and {align}-byte aligned"
            ));
        }
        Ok(())
    }

    /// Check alignment and the entire context's address range against XLEN.
    /// This does not prove that guest memory is mapped or exclusively owned.
    pub fn validate_address(self, address: u64) -> Result<(), String> {
        self.check_address(address, TASK_ALIGN)?;
        let last = address
            .checked_add(self.size() as u64 - 1)
            .ok_or("task context address overflow")?;
        self.check_word(last)
    }

    fn put(self, image: &mut [u8], offset: usize, value: u64) {
        image[offset..offset + self.word_bytes()]
            .copy_from_slice(&value.to_le_bytes()[..self.word_bytes()]);
    }

    fn get(self, image: &[u8], offset: usize) -> u64 {
        let mut bytes = [0; 8];
        bytes[..self.word_bytes()].copy_from_slice(&image[offset..offset + self.word_bytes()]);
        u64::from_le_bytes(bytes)
    }

    /// Prepare storage for saving an already running task (e.g. Adam).
    /// It is not resumable until a successful switch has filled its registers.
    pub fn empty_context(self, address: u64, hart_id: u64) -> Result<Vec<u8>, String> {
        self.validate_address(address)?;
        self.check_word(hart_id)?;
        let mut image = vec![0; self.size()];
        self.put(&mut image, self.hart_offset(), hart_id);
        Ok(image)
    }

    /// Create a resumable context for the first-entry trampoline. s0/s1/s2 hold
    /// handler/argument/exit respectively; remaining saved registers start zero.
    /// Stack capacity beyond the 16-byte ABI minimum is the integrator's duty.
    pub fn initial_context(self, address: u64, start: TaskStart) -> Result<Vec<u8>, String> {
        let mut image = self.empty_context(address, start.hart_id)?;
        self.check_address(start.stack_base, TASK_ALIGN)?;
        if start.stack_bytes < TASK_ALIGN || start.stack_bytes % TASK_ALIGN != 0 {
            return Err("task stack extent must be a nonzero multiple of 16".into());
        }
        let top = start
            .stack_base
            .checked_add(start.stack_bytes)
            .ok_or("task stack address overflow")?;
        self.check_address(top, TASK_ALIGN)?;
        if address < top && start.stack_base <= address + (self.size() as u64 - 1) {
            return Err("task stack overlaps its context".into());
        }
        for pc in [start.entry_pc, start.handler_pc, start.exit_pc] {
            self.check_address(pc, 4)?;
        }
        self.check_word(start.argument)?;
        for (register, value) in [
            (RA, start.entry_pc),
            (SP, top),
            (8, start.handler_pc),
            (9, start.argument),
            (18, start.exit_pc),
        ] {
            self.put(&mut image, self.register_offset(register)?, value);
        }
        self.put(
            &mut image,
            self.sie_offset(),
            if start.enable_interrupts {
                SSTATUS_SIE as u64
            } else {
                0
            },
        );
        Ok(image)
    }

    fn validate_owner(self, address: u64, image: &[u8], hart_id: u64) -> Result<(), String> {
        self.validate_address(address)?;
        self.check_word(hart_id)?;
        if image.len() != self.size() {
            return Err("task context has the wrong XLEN/layout size".into());
        }
        if self.get(image, self.hart_offset()) != hart_id {
            return Err("task migration is forbidden: context owner differs from hart".into());
        }
        Ok(())
    }

    /// Validate a resumable image's layout, owner, aligned ra/sp and SIE mask.
    pub fn validate_context(self, address: u64, image: &[u8], hart_id: u64) -> Result<(), String> {
        self.validate_owner(address, image, hart_id)?;
        self.check_address(self.get(image, self.register_offset(RA)?), 4)?;
        self.check_address(self.get(image, self.register_offset(SP)?), TASK_ALIGN)?;
        if self.get(image, self.sie_offset()) & !(SSTATUS_SIE as u64) != 0 {
            return Err("task SIE slot contains non-SIE status bits".into());
        }
        Ok(())
    }

    /// Validate a distinct, nonoverlapping switch pair before handing addresses
    /// to the generated routine. The outgoing image may be an empty context.
    pub fn validate_switch(
        self,
        old_address: u64,
        old: &[u8],
        next_address: u64,
        next: &[u8],
        hart_id: u64,
    ) -> Result<(), String> {
        self.validate_owner(old_address, old, hart_id)?;
        self.validate_context(next_address, next, hart_id)?;
        if old_address.abs_diff(next_address) < self.size() as u64 {
            return Err("task switch contexts overlap".into());
        }
        Ok(())
    }

    fn load(self, rd: u32, rs: u32, offset: usize) -> Op {
        let off = offset as i32;
        if self.xlen == 32 {
            Op::Lw { rd, rs, off }
        } else {
            Op::Ld { rd, rs, off }
        }
    }

    fn store(self, rs2: u32, rs1: u32, offset: usize) -> Op {
        let off = offset as i32;
        if self.xlen == 32 {
            Op::Sw { rs2, rs1, off }
        } else {
            Op::Sd { rs2, rs1, off }
        }
    }
}

fn module(ops: Vec<Op>) -> Module {
    Module {
        nodes: vec![Node {
            purpose: Purpose::Topology,
            ops,
        }],
        ..Module::default()
    }
}

/// Generate `g6b_task_switch(a0=old, a1=next)`. A resumed call returns a0=0.
/// Runtime rejection returns a0=-1 on the original stack with original SIE;
/// neither context nor any callee-saved register is changed on rejection.
///
/// ra/sp/s0..s11 and only sstatus.SIE are saved/restored. gp/tp, satp and other
/// CSRs remain hart-owned. Caller-saved integer registers may be clobbered.
/// SIE is atomically cleared before context access and restored only after the
/// new stack/registers are live, immediately before ret. This is a normal call,
/// never a trap return. Call only at cooperative integer-ABI yield points.
///
/// Use [`TaskLayout::validate_switch`] first: the runtime checks null/alignment,
/// distinct pointers, owner hart, incoming ra/sp/SIE and outgoing sp/ra, but
/// cannot prove memory accessibility, extent, nonoverlap or stack ownership.
/// Contexts must not be concurrently modified, even by interrupt handlers.
/// Append this module's nodes once to the payload and resolve calls by symbol.
pub fn task_switch_ir(xlen: u32) -> Result<Module, String> {
    let layout = TaskLayout::new(xlen)?;
    let reject = "g6b_task_switch_reject";
    let mut ops = vec![
        Op::Glob(TASK_SWITCH.into()),
        Op::Label(TASK_SWITCH.into()),
        Op::Li {
            rd: T1,
            imm: SSTATUS_SIE,
        },
        Op::Csrrc {
            rd: T0,
            csr: CSR_SSTATUS,
            rs: T1,
        },
        Op::Srli {
            rd: T2,
            rs: T0,
            shamt: 9,
        },
        Op::Andi {
            rd: T2,
            rs: T2,
            imm: 0xf3,
        },
        Op::Andi {
            rd: T0,
            rs: T0,
            imm: SSTATUS_SIE as i32,
        },
        Op::Bne {
            rs1: T2,
            rs2: X0,
            to: reject.into(),
        },
        Op::Beq {
            rs1: A0,
            rs2: A1,
            to: reject.into(),
        },
    ];
    for (rs, align) in [
        (A0, TASK_ALIGN),
        (A1, TASK_ALIGN),
        (SP, TASK_ALIGN),
        (RA, 4),
    ] {
        ops.extend([
            Op::Beq {
                rs1: rs,
                rs2: X0,
                to: reject.into(),
            },
            Op::Andi {
                rd: T1,
                rs,
                imm: align as i32 - 1,
            },
            Op::Bne {
                rs1: T1,
                rs2: X0,
                to: reject.into(),
            },
        ]);
    }
    for rs in [A0, A1] {
        ops.extend([
            layout.load(T1, rs, layout.hart_offset()),
            Op::Bne {
                rs1: T1,
                rs2: TP,
                to: reject.into(),
            },
        ]);
    }
    for (register, align) in [(RA, 4), (SP, TASK_ALIGN)] {
        ops.extend([
            layout.load(T2, A1, layout.register_offset(register)?),
            Op::Beq {
                rs1: T2,
                rs2: X0,
                to: reject.into(),
            },
            Op::Andi {
                rd: T1,
                rs: T2,
                imm: align as i32 - 1,
            },
            Op::Bne {
                rs1: T1,
                rs2: X0,
                to: reject.into(),
            },
        ]);
    }
    ops.extend([
        layout.load(T2, A1, layout.sie_offset()),
        Op::Andi {
            rd: T1,
            rs: T2,
            imm: !(SSTATUS_SIE as i32),
        },
        Op::Bne {
            rs1: T1,
            rs2: X0,
            to: reject.into(),
        },
    ]);
    for (slot, register) in TASK_REGISTERS.iter().enumerate() {
        ops.push(layout.store(*register, A0, slot * layout.word_bytes()));
    }
    ops.push(layout.store(T0, A0, layout.sie_offset()));
    ops.push(layout.load(T0, A1, layout.sie_offset()));
    for (slot, register) in TASK_REGISTERS.iter().enumerate() {
        ops.push(layout.load(*register, A1, slot * layout.word_bytes()));
    }
    ops.extend([
        Op::Li { rd: A0, imm: 0 },
        Op::Csrrs {
            rd: X0,
            csr: CSR_SSTATUS,
            rs: T0,
        },
        Op::Jalr {
            rd: X0,
            rs: RA,
            imm: 0,
        },
        Op::Label(reject.into()),
        Op::Li { rd: A0, imm: -1 },
        Op::Csrrs {
            rd: X0,
            csr: CSR_SSTATUS,
            rs: T0,
        },
        Op::Jalr {
            rd: X0,
            rs: RA,
            imm: 0,
        },
    ]);
    Ok(module(ops))
}

/// Generate the first-entry trampoline for [`TaskLayout::initial_context`].
/// Calls s0(a0=s1), then s2(a0=handler result). The integer ABI requires the
/// handler to preserve s2 (exit hook) and all other callee-saved registers.
/// The exit hook must not return and must not free the active stack before
/// switching away. If it returns incorrectly, SIE is masked and the hart parks
/// forever (WFI plus back-edge, not a return through stale ra). No stack frame
/// is needed: this trampoline never resumes its own caller.
pub fn task_entry_ir(xlen: u32) -> Result<Module, String> {
    TaskLayout::new(xlen)?;
    Ok(module(vec![
        Op::Glob(TASK_ENTRY.into()),
        Op::Label(TASK_ENTRY.into()),
        Op::Addi {
            rd: A0,
            rs: 9,
            imm: 0,
        },
        Op::Jalr {
            rd: RA,
            rs: 8,
            imm: 0,
        },
        Op::Jalr {
            rd: RA,
            rs: 18,
            imm: 0,
        },
        Op::Li {
            rd: T0,
            imm: SSTATUS_SIE,
        },
        Op::Csrrc {
            rd: X0,
            csr: CSR_SSTATUS,
            rs: T0,
        },
        Op::Label("g6b_task_entry_park".into()),
        Op::Wfi,
        Op::Jal {
            rd: X0,
            to: "g6b_task_entry_park".into(),
        },
    ]))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn start() -> TaskStart {
        TaskStart {
            hart_id: 3,
            stack_base: 0x4000,
            stack_bytes: 0x1000,
            entry_pc: 0x1000,
            handler_pc: 0x1100,
            argument: 0xfedc_ba98,
            exit_pc: 0x1200,
            enable_interrupts: true,
        }
    }

    #[test]
    fn layout_and_initial_images_rv32_rv64() {
        for xlen in [32, 64] {
            let layout = TaskLayout::new(xlen).unwrap();
            let bytes = (xlen / 8) as usize;
            assert_eq!(layout.xlen(), xlen);
            assert_eq!(layout.size(), 16 * bytes);
            for (slot, register) in TASK_REGISTERS.iter().enumerate() {
                assert_eq!(layout.register_offset(*register).unwrap(), slot * bytes);
            }
            for register in [0, 3, 4, 5, 10, 31, 32] {
                assert!(layout.register_offset(register).is_err());
            }
            let image = layout.initial_context(0x2000, start()).unwrap();
            layout.validate_context(0x2000, &image, 3).unwrap();
            for (slot, value) in [
                (0, 0x1000),
                (1, 0x5000),
                (2, 0x1100),
                (3, 0xfedc_ba98),
                (4, 0x1200),
                (5, 0),
                (13, 0),
                (14, 2),
                (15, 3),
            ] {
                assert_eq!(layout.get(&image, slot * bytes), value);
            }
            let old = layout.empty_context(0x3000, 3).unwrap();
            layout
                .validate_switch(0x3000, &old, 0x2000, &image, 3)
                .unwrap();
            assert!(layout.validate_context(0x3000, &old, 3).is_err());
            assert!(layout
                .validate_switch(0x2000, &old, 0x2000, &image, 3)
                .is_err());
            assert!(layout
                .validate_switch(0x2010, &old, 0x2000, &image, 3)
                .is_err());
            assert!(layout
                .validate_switch(0x3000, &old, 0x2000, &image, 2)
                .is_err());
        }
    }

    #[test]
    fn invalid_xlen_addresses_and_layout_are_rejected() {
        for xlen in [0, 16, 33, 128] {
            assert!(TaskLayout::new(xlen).is_err());
            assert!(task_switch_ir(xlen).is_err());
            assert!(task_entry_ir(xlen).is_err());
        }
        for xlen in [32, 64] {
            let layout = TaskLayout::new(xlen).unwrap();
            for address in [0, 1, 0x2008, u64::MAX - 15] {
                assert!(layout.initial_context(address, start()).is_err());
            }
            for bad in [
                TaskStart {
                    stack_base: 0,
                    ..start()
                },
                TaskStart {
                    stack_base: 0x4008,
                    ..start()
                },
                TaskStart {
                    stack_base: u64::MAX - 15,
                    ..start()
                },
                TaskStart {
                    stack_bytes: 0,
                    ..start()
                },
                TaskStart {
                    stack_bytes: 17,
                    ..start()
                },
                TaskStart {
                    stack_base: 0x2000,
                    ..start()
                },
                TaskStart {
                    entry_pc: 0,
                    ..start()
                },
                TaskStart {
                    handler_pc: 0x1102,
                    ..start()
                },
                TaskStart {
                    exit_pc: 0x1201,
                    ..start()
                },
            ] {
                assert!(layout.initial_context(0x2000, bad).is_err(), "{bad:?}");
            }
            let image = layout.initial_context(0x2000, start()).unwrap();
            assert!(layout
                .validate_context(0x2000, &image[..image.len() - 1], 3)
                .is_err());
            for (offset, value) in [(0, 0), (bytes_sp(layout), 7), (layout.sie_offset(), 0x22)] {
                let mut bad = image.clone();
                layout.put(&mut bad, offset, value);
                assert!(layout.validate_context(0x2000, &bad, 3).is_err());
            }
        }
        let rv32 = TaskLayout::new(32).unwrap();
        assert!(rv32.validate_address(0xffff_fff0).is_err());
        assert!(rv32.empty_context(0x2000, 1 << 32).is_err());
        for bad in [
            TaskStart {
                argument: 1 << 32,
                ..start()
            },
            TaskStart {
                handler_pc: 1 << 32,
                ..start()
            },
            TaskStart {
                stack_base: 0xffff_f000,
                ..start()
            },
        ] {
            assert!(rv32.initial_context(0x2000, bad).is_err());
        }
        let rv64 = TaskLayout::new(64).unwrap();
        assert!(rv64
            .initial_context(
                0x2000,
                TaskStart {
                    argument: u64::MAX,
                    ..start()
                }
            )
            .is_ok());
    }

    fn bytes_sp(layout: TaskLayout) -> usize {
        layout.register_offset(SP).unwrap()
    }

    #[test]
    fn task_modules_use_one_lower_and_valid_register_names() {
        for xlen in [32, 64] {
            let switch = task_switch_ir(xlen).unwrap();
            let entry = task_entry_ir(xlen).unwrap();
            for m in [&switch, &entry] {
                assert!(m.nodes.iter().all(|n| n.purpose == Purpose::Topology));
                assert!(!m
                    .nodes
                    .iter()
                    .flat_map(|n| &n.ops)
                    .any(|op| matches!(op, Op::Word(_))));
                assert!(m.to_words(0x1000).is_ok());
                assert!(!m.to_asm().contains("x?"));
                assert!(m.to_asm().contains("csrrc"));
            }
            let asm = switch.to_asm();
            assert!(asm.contains(if xlen == 32 { "sw\ts11" } else { "sd\ts11" }));
            assert!(asm.contains(if xlen == 32 { "lw\ts11" } else { "ld\ts11" }));
        }
    }
}
