// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Lower a WASM i32.add export to RISC-V (`g6b-asm`).

#![allow(missing_docs)]

use g6b_asm::encode::{A0, A1, A2, A3, RA, SP, T0, T1, T2, X0};
use g6b_asm::{Addr, Module, Node, Op, Purpose};

pub const MAX_JIT_SLOTS: usize = 256;
pub const MAX_JIT_INSTRUCTIONS: usize = 4096;

pub fn jit_riscv(m: &crate::Module, export: &str, xlen: u32) -> Result<Module, String> {
    use crate::Instr;
    if !matches!(xlen, 32 | 64) {
        return Err("JIT requires RV32IM or RV64IM".into());
    }
    let valid_symbol = export
        .bytes()
        .enumerate()
        .all(|(i, b)| b == b'_' || b.is_ascii_alphabetic() || (i != 0 && b.is_ascii_digit()));
    if export.is_empty() || !valid_symbol {
        return Err("JIT export is not an assembler symbol".into());
    }
    let analysis = crate::binary::analyze(m)?;
    let idx = m
        .exports
        .iter()
        .find(|e| e.kind == 0 && e.name == export)
        .ok_or("no numeric export")?
        .idx;
    let local = (idx as usize)
        .checked_sub(m.imports.len())
        .ok_or("cannot JIT host import")?;
    let ty = crate::binary::func_type(m, idx)?;
    let locals = ty.params as usize + m.locals[local] as usize;
    let slots = locals + analysis[local].max_stack;
    let body = &m.bodies[local];
    if ty.params > 3 || slots > MAX_JIT_SLOTS || body.len() > MAX_JIT_INSTRUCTIONS {
        return Err("JIT numeric resource limit".into());
    }
    for (pc, ins) in body.iter().enumerate() {
        match ins {
            Instr::I32Const(_)
            | Instr::LocalGet(_)
            | Instr::LocalSet(_)
            | Instr::LocalTee(_)
            | Instr::Drop
            | Instr::Nop
            | Instr::I32Add
            | Instr::I32Sub
            | Instr::I32Mul
            | Instr::I32Xor
            | Instr::I32And
            | Instr::I32Or
            | Instr::I32Shl
            | Instr::I32ShrS
            | Instr::I32ShrU
            | Instr::I32Rotl
            | Instr::I32Rotr
            | Instr::I32LtS
            | Instr::I32LtU
            | Instr::I32GtS
            | Instr::I32GtU
            | Instr::I32LeS
            | Instr::I32LeU
            | Instr::I32GeS
            | Instr::I32GeU
            | Instr::I32Eq
            | Instr::I32Ne
            | Instr::I32Eqz
            | Instr::Select => {}
            Instr::End if pc + 1 == body.len() => {}
            Instr::Return if pc + 2 == body.len() => {}
            _ => return Err(format!("unsupported JIT instruction {ins:?}")),
        }
    }
    let frame = (slots * 4).max(16).div_ceil(16) * 16;
    let mut ops = vec![
        Op::Glob(export.into()),
        Op::Label(export.into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -(frame as i32),
        },
    ];
    for i in 0..locals {
        ops.push(store(
            if i < ty.params as usize {
                A0 + i as u32
            } else {
                X0
            },
            i,
        ));
    }
    let mut height = 0usize;
    for (pc, ins) in body.iter().enumerate() {
        match ins {
            Instr::I32Const(value) => {
                ops.push(Op::Li {
                    rd: T0,
                    imm: i64::from(*value),
                });
                ops.push(store(T0, locals + height));
                height += 1;
            }
            Instr::LocalGet(i) => {
                ops.push(load(T0, *i as usize));
                ops.push(store(T0, locals + height));
                height += 1;
            }
            Instr::LocalSet(i) | Instr::LocalTee(i) => {
                ops.push(load(T0, locals + height - 1));
                ops.push(store(T0, *i as usize));
                if matches!(ins, Instr::LocalSet(_)) {
                    height -= 1;
                }
            }
            Instr::Drop => height -= 1,
            Instr::Nop => {}
            Instr::I32Add | Instr::I32Sub | Instr::I32Mul | Instr::I32Xor => {
                ops.push(load(T0, locals + height - 2));
                ops.push(load(T1, locals + height - 1));
                ops.push(match ins {
                    Instr::I32Add => Op::Add {
                        rd: T0,
                        rs1: T0,
                        rs2: T1,
                    },
                    Instr::I32Sub => Op::Sub {
                        rd: T0,
                        rs1: T0,
                        rs2: T1,
                    },
                    Instr::I32Mul => Op::Mul {
                        rd: T0,
                        rs1: T0,
                        rs2: T1,
                    },
                    _ => Op::Xor {
                        rd: T0,
                        rs1: T0,
                        rs2: T1,
                    },
                });
                height -= 1;
                ops.push(store(T0, locals + height - 1));
            }
            Instr::I32And | Instr::I32Or => {
                ops.push(load(T0, locals + height - 2));
                ops.push(load(T1, locals + height - 1));
                lower_bitwise(&mut ops, matches!(ins, Instr::I32Or), xlen);
                height -= 1;
                ops.push(store(T0, locals + height - 1));
            }
            Instr::I32Shl | Instr::I32ShrS | Instr::I32ShrU | Instr::I32Rotl | Instr::I32Rotr => {
                ops.push(load(T0, locals + height - 2));
                ops.push(load(T1, locals + height - 1));
                lower_shift(&mut ops, ins, xlen, &format!("{export}__g6b_shift_{pc}"));
                height -= 1;
                ops.push(store(T0, locals + height - 1));
            }
            Instr::I32LtS
            | Instr::I32LtU
            | Instr::I32GtS
            | Instr::I32GtU
            | Instr::I32LeS
            | Instr::I32LeU
            | Instr::I32GeS
            | Instr::I32GeU => {
                let reverse = matches!(
                    ins,
                    Instr::I32GtS | Instr::I32GtU | Instr::I32LeS | Instr::I32LeU
                );
                ops.push(load(T0, locals + height - if reverse { 1 } else { 2 }));
                ops.push(load(T1, locals + height - if reverse { 2 } else { 1 }));
                let unsigned = matches!(
                    ins,
                    Instr::I32LtU | Instr::I32GtU | Instr::I32LeU | Instr::I32GeU
                );
                let invert = matches!(
                    ins,
                    Instr::I32LeS | Instr::I32LeU | Instr::I32GeS | Instr::I32GeU
                );
                lower_ordering(
                    &mut ops,
                    unsigned,
                    invert,
                    &format!("{export}__g6b_order_{pc}"),
                );
                height -= 1;
                ops.push(store(T0, locals + height - 1));
            }
            Instr::I32Eq | Instr::I32Ne | Instr::I32Eqz => {
                let unary = matches!(ins, Instr::I32Eqz);
                ops.push(load(T0, locals + height - if unary { 1 } else { 2 }));
                if !unary {
                    ops.push(load(T1, locals + height - 1));
                    height -= 1;
                }
                let done = format!("{export}__g6b_cmp_{pc}");
                ops.push(Op::Li { rd: T2, imm: 1 });
                ops.push(if matches!(ins, Instr::I32Ne) {
                    Op::Bne {
                        rs1: T0,
                        rs2: T1,
                        to: done.clone(),
                    }
                } else {
                    Op::Beq {
                        rs1: T0,
                        rs2: if unary { X0 } else { T1 },
                        to: done.clone(),
                    }
                });
                ops.push(Op::Li { rd: T2, imm: 0 });
                ops.push(Op::Label(done));
                ops.push(store(T2, locals + height - 1));
            }
            Instr::Select => {
                ops.push(load(T0, locals + height - 3));
                ops.push(load(T1, locals + height - 2));
                ops.push(load(T2, locals + height - 1));
                let done = format!("{export}__g6b_select_{pc}");
                ops.push(Op::Bne {
                    rs1: T2,
                    rs2: X0,
                    to: done.clone(),
                });
                ops.push(Op::Addi {
                    rd: T0,
                    rs: T1,
                    imm: 0,
                });
                ops.push(Op::Label(done));
                height -= 2;
                ops.push(store(T0, locals + height - 1));
            }
            Instr::Return | Instr::End => {
                if ty.results == 1 {
                    ops.push(load(A0, locals + height - 1));
                }
                break;
            }
            _ => return Err("unsupported JIT instruction".into()),
        }
    }
    ops.extend([
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: frame as i32,
        },
        Op::Jalr {
            rd: X0,
            rs: RA,
            imm: 0,
        },
    ]);
    let mut lowered = Module::default();
    lowered.push(Node {
        purpose: Purpose::WasmJit,
        ops,
    });
    Ok(lowered)
}

fn lower_bitwise(ops: &mut Vec<Op>, is_or: bool, xlen: u32) {
    if xlen == 32 {
        ops.extend([
            Op::Srli {
                rd: T2,
                rs: T0,
                shamt: 31,
            },
            Op::Srli {
                rd: A0,
                rs: T1,
                shamt: 31,
            },
            Op::Mul {
                rd: T2,
                rs1: T2,
                rs2: A0,
            },
            Op::Slli {
                rd: T2,
                rs: T2,
                shamt: 31,
            },
        ]);
    }
    ops.extend([
        Op::Xor {
            rd: A0,
            rs1: T0,
            rs2: T1,
        },
        Op::Add {
            rd: T0,
            rs1: T0,
            rs2: T1,
        },
        Op::Sub {
            rd: T0,
            rs1: T0,
            rs2: A0,
        },
    ]);
    logical_shift_right(ops, T0, T0, 1, xlen);
    if xlen == 32 {
        ops.push(Op::Add {
            rd: T0,
            rs1: T0,
            rs2: T2,
        });
    }
    if is_or {
        ops.push(Op::Add {
            rd: T0,
            rs1: T0,
            rs2: A0,
        });
    }
}

fn logical_shift_right(ops: &mut Vec<Op>, rd: u32, rs: u32, shamt: u32, xlen: u32) {
    if xlen == 64 {
        ops.push(Op::Srli { rd, rs, shamt });
    } else {
        ops.extend([
            Op::Srli {
                rd: A1,
                rs,
                shamt: 31,
            },
            Op::Andi {
                rd: A1,
                rs: A1,
                imm: 1,
            },
            Op::Slli {
                rd: A2,
                rs: A1,
                shamt: 31,
            },
            Op::Sub {
                rd,
                rs1: rs,
                rs2: A2,
            },
            Op::Srli { rd, rs: rd, shamt },
            Op::Slli {
                rd: A1,
                rs: A1,
                shamt: 31 - shamt,
            },
            Op::Add {
                rd,
                rs1: rd,
                rs2: A1,
            },
        ]);
    }
}

fn zero_extend_i32(ops: &mut Vec<Op>, xlen: u32) {
    if xlen == 64 {
        ops.extend([
            Op::Slli {
                rd: T0,
                rs: T0,
                shamt: 32,
            },
            Op::Srli {
                rd: T0,
                rs: T0,
                shamt: 32,
            },
        ]);
    }
}

fn lower_shift(ops: &mut Vec<Op>, ins: &crate::Instr, xlen: u32, label: &str) {
    use crate::Instr;
    let signed = matches!(ins, Instr::I32ShrS);
    let rotate = matches!(ins, Instr::I32Rotl | Instr::I32Rotr);
    if signed {
        ops.extend([
            Op::Srli {
                rd: T2,
                rs: T0,
                shamt: 31,
            },
            Op::Andi {
                rd: T2,
                rs: T2,
                imm: 1,
            },
            Op::Sub {
                rd: A0,
                rs1: X0,
                rs2: T2,
            },
            Op::Xor {
                rd: T0,
                rs1: T0,
                rs2: A0,
            },
        ]);
    } else if rotate || matches!(ins, Instr::I32ShrU) {
        zero_extend_i32(ops, xlen);
    }
    for bit in 0..5 {
        let shamt = 1 << bit;
        let skip = format!("{label}_{bit}");
        ops.extend([
            Op::Andi {
                rd: T2,
                rs: T1,
                imm: shamt as i32,
            },
            Op::Beq {
                rs1: T2,
                rs2: X0,
                to: skip.clone(),
            },
        ]);
        if rotate {
            if matches!(ins, Instr::I32Rotl) {
                logical_shift_right(ops, T2, T0, 32 - shamt, xlen);
            } else {
                ops.push(Op::Slli {
                    rd: T2,
                    rs: T0,
                    shamt: 32 - shamt,
                });
            }
        }
        if matches!(ins, Instr::I32Shl | Instr::I32Rotl) {
            ops.push(Op::Slli {
                rd: T0,
                rs: T0,
                shamt,
            });
        } else {
            logical_shift_right(ops, T0, T0, shamt, xlen);
        }
        if rotate {
            ops.push(Op::Add {
                rd: T0,
                rs1: T0,
                rs2: T2,
            });
            zero_extend_i32(ops, xlen);
        }
        ops.push(Op::Label(skip));
    }
    if signed {
        ops.push(Op::Xor {
            rd: T0,
            rs1: T0,
            rs2: A0,
        });
    }
}

fn lower_ordering(ops: &mut Vec<Op>, unsigned: bool, invert: bool, label: &str) {
    let different = format!("{label}_signs");
    let done = format!("{label}_done");
    ops.extend([
        Op::Xor {
            rd: T2,
            rs1: T0,
            rs2: T1,
        },
        Op::Srli {
            rd: T2,
            rs: T2,
            shamt: 31,
        },
        Op::Andi {
            rd: T2,
            rs: T2,
            imm: 1,
        },
        Op::Bne {
            rs1: T2,
            rs2: X0,
            to: different.clone(),
        },
        Op::Sub {
            rd: T0,
            rs1: T0,
            rs2: T1,
        },
        Op::Srli {
            rd: T0,
            rs: T0,
            shamt: 31,
        },
        Op::Jal {
            rd: X0,
            to: done.clone(),
        },
        Op::Label(different),
        Op::Srli {
            rd: T0,
            rs: if unsigned { T1 } else { T0 },
            shamt: 31,
        },
        Op::Label(done),
        Op::Andi {
            rd: T0,
            rs: T0,
            imm: 1,
        },
    ]);
    if invert {
        ops.extend([
            Op::Li { rd: T2, imm: 1 },
            Op::Xor {
                rd: T0,
                rs1: T0,
                rs2: T2,
            },
        ]);
    }
}

fn load(rd: u32, slot: usize) -> Op {
    Op::Lw {
        rd,
        rs: SP,
        off: (slot * 4) as i32,
    }
}

fn store(rs2: u32, slot: usize) -> Op {
    Op::Sw {
        rs2,
        rs1: SP,
        off: (slot * 4) as i32,
    }
}

/// Guest lower of `(i32, i32) -> i32` add — the WASM-JIT ISel smoke.
pub fn jit_add_i32() -> Module {
    let mut m = Module::default();
    m.push(Node {
        purpose: Purpose::WasmJit,
        ops: vec![
            Op::Comment(
                "WASM-JIT i32.add → add a0, a0, a1 (svelte-d / libwasm numeric leaf)".into(),
            ),
            Op::Glob("wasm_add_i32".into()),
            Op::Label("wasm_add_i32".into()),
            Op::Addi {
                rd: SP,
                rs: SP,
                imm: -16,
            },
            Op::Add {
                rd: A0,
                rs1: A0,
                rs2: A1,
            },
            store(A0, 0),
            load(A0, 0),
            Op::Addi {
                rd: SP,
                rs: SP,
                imm: 16,
            },
            Op::Jalr {
                rd: X0,
                rs: RA,
                imm: 0,
            },
        ],
    });
    m
}

/// Byte cap for the guest `__wasm_data` rodata image (data section only).
pub const MAX_WASM_DATA: usize = 16 * 1024;

/// Guest `env` import stubs provided by `g6b-asm::dom` (lirx-dom-shaped DOM
/// store + kernel router). `Ptr` args index the wasm data image (`__wasm_data`).
#[derive(Clone, Copy)]
enum Arg {
    Ptr,
    Imm,
}

fn import_stub(name: &str) -> Option<(&'static str, &'static [Arg])> {
    match name {
        crate::IMPORT_SET_INNER_TEXT => {
            Some(("WasmDomText", &[Arg::Ptr, Arg::Imm, Arg::Ptr, Arg::Imm]))
        }
        crate::IMPORT_SET_VISIBLE => Some(("WasmDomVisible", &[Arg::Ptr, Arg::Imm, Arg::Imm])),
        crate::IMPORT_FETCH | crate::IMPORT_OBJECT_CALL => {
            Some(("WasmFetch", &[Arg::Ptr, Arg::Imm]))
        }
        crate::IMPORT_LOG => Some(("WasmLog", &[Arg::Ptr, Arg::Imm])),
        _ => None,
    }
}

/// Linear-memory snapshot for `__wasm_data`: the decoded data image trimmed to
/// its last non-zero byte (4-aligned). Strings referenced by `_start` imports
/// resolve as `__wasm_data + ptr`.
pub fn data_image(m: &crate::Module) -> Result<Vec<u8>, String> {
    let end = m.memory.iter().rposition(|b| *b != 0).map_or(0, |i| i + 1);
    let end = end.div_ceil(4) * 4;
    if end > MAX_WASM_DATA {
        return Err("wasm data image limit".into());
    }
    Ok(m.memory[..end].to_vec())
}

/// Lower a straight-line `_start` (`i32.const` + `call` env imports + `end`)
/// to the guest `WasmStart` routine — the WASM-JIT UI path. The ops reference
/// `WasmDomText`/`WasmDomVisible`/`WasmFetch`/`WasmLog` and `__wasm_data`,
/// provided by `g6b-asm::dom` / `Module::wasm_data` at ELF build. Anything
/// else fails closed.
pub fn start_ops(m: &crate::Module, xlen: u32) -> Result<Vec<Op>, String> {
    use crate::Instr;
    if !matches!(xlen, 32 | 64) {
        return Err("WasmStart requires RV32IM or RV64IM".into());
    }
    let idx = m
        .exports
        .iter()
        .find(|e| e.kind == 0 && e.name == "_start")
        .ok_or("no _start export")?
        .idx;
    let local = (idx as usize)
        .checked_sub(m.imports.len())
        .ok_or("cannot JIT the _start import")?;
    let ty = crate::binary::func_type(m, idx)?;
    if ty.params != 0 || ty.results != 0 {
        return Err("_start must be () -> ()".into());
    }
    if m.locals.get(local).copied().unwrap_or(0) != 0 {
        return Err("_start locals unsupported in guest JIT".into());
    }
    let body = m.bodies.get(local).ok_or("_start body")?;
    if body.len() > MAX_JIT_INSTRUCTIONS {
        return Err("JIT instruction limit".into());
    }
    let (st_ra, ld_ra) = if xlen == 64 {
        (
            Op::Sd {
                rs2: RA,
                rs1: SP,
                off: 8,
            },
            Op::Ld {
                rd: RA,
                rs: SP,
                off: 8,
            },
        )
    } else {
        (
            Op::Sw {
                rs2: RA,
                rs1: SP,
                off: 8,
            },
            Op::Lw {
                rd: RA,
                rs: SP,
                off: 8,
            },
        )
    };
    let mut ops = vec![
        Op::Comment("WasmStart — guest ISel of wasm _start: i32.const + env import calls".into()),
        Op::Glob("WasmStart".into()),
        Op::Label("WasmStart".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -16,
        },
        st_ra,
    ];
    let mut stack: Vec<i32> = Vec::new();
    let mut ended = false;
    for (pc, ins) in body.iter().enumerate() {
        match ins {
            Instr::I32Const(v) => {
                stack.push(*v);
                if stack.len() > 8 {
                    return Err("_start operand stack limit".into());
                }
            }
            Instr::Call(f) => {
                let im = m
                    .imports
                    .get(*f as usize)
                    .ok_or("guest JIT supports env imports only (no local calls)")?;
                if im.module != "env" {
                    return Err(format!("unknown import module {}", im.module));
                }
                let params = crate::binary::func_type(m, *f)?.params as usize;
                let (stub, kinds) = import_stub(&im.name)
                    .ok_or_else(|| format!("unsupported guest import {}", im.name))?;
                if params != kinds.len() {
                    return Err(format!("import {} arity mismatch", im.name));
                }
                let base = stack
                    .len()
                    .checked_sub(params)
                    .ok_or("call argument underflow")?;
                let args: Vec<i32> = stack.split_off(base);
                for (i, (v, kind)) in args.iter().zip(kinds).enumerate() {
                    let reg = A0 + i as u32;
                    if reg > A3 {
                        return Err("guest import arity limit".into());
                    }
                    match kind {
                        Arg::Ptr => {
                            ops.push(Op::La {
                                rd: reg,
                                addr: Addr::WasmData,
                            });
                            ops.push(Op::Li {
                                rd: T0,
                                imm: i64::from(*v),
                            });
                            ops.push(Op::Add {
                                rd: reg,
                                rs1: reg,
                                rs2: T0,
                            });
                        }
                        Arg::Imm => ops.push(Op::Li {
                            rd: reg,
                            imm: i64::from(*v),
                        }),
                    }
                }
                ops.push(Op::Jal {
                    rd: RA,
                    to: stub.into(),
                });
            }
            Instr::End | Instr::Return if pc + 1 == body.len() => {
                ended = true;
                break;
            }
            _ => {
                return Err(format!(
                    "unsupported _start instruction {ins:?} (guest JIT is straight-line)"
                ))
            }
        }
    }
    if !ended || !stack.is_empty() {
        return Err("_start did not end cleanly for guest JIT".into());
    }
    ops.extend([
        ld_ra,
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 16,
        },
        Op::Jalr {
            rd: X0,
            rs: RA,
            imm: 0,
        },
    ]);
    Ok(ops)
}

/// Install `start_ops` onto a payload module's `WasmStart` anchor and set
/// `module.wasm_data` — the shared merge used by `g6b-elf` (ELF + smoke) and
/// `g6b-design` (`KStart.S`) so the listing cannot diverge from the payload.
/// The anchor label must already exist (`g6b-asm::dom::attach`).
pub fn install_start(module: &mut Module, xlen: u32) -> Result<(), String> {
    let wm = crate::decode(crate::BIOS_UI_WASM)?;
    let ops = start_ops(&wm, xlen)?;
    let data = data_image(&wm)?;
    let mut merged = false;
    for n in &mut module.nodes {
        if n.ops
            .iter()
            .any(|o| matches!(o, Op::Label(l) if l == "WasmStart"))
        {
            n.ops = ops.clone();
            merged = true;
            break;
        }
    }
    if !merged {
        return Err("WasmStart anchor missing in payload".into());
    }
    module.wasm_data = data;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::binary::tests::numeric;
    use crate::interp::tests::TestHost;
    use crate::{decode, run};
    use g6b_asm::encode::A7;
    use g6b_asm::{exec, Addr};

    fn differential(bytes: &[u8], args: &[i32]) {
        check_numeric(bytes, args, false);
    }

    fn check_numeric(bytes: &[u8], args: &[i32], facade: bool) {
        let m = decode(bytes).unwrap();
        let expected = run(&m, 0, args, &mut TestHost::default()).unwrap()[0];
        let execute = |spec, xlen| {
            let symbol = if facade { "wasm_add_i32" } else { "main" };
            let mut lowered = if facade {
                jit_add_i32()
            } else {
                jit_riscv(&m, symbol, xlen).unwrap()
            };
            assert_eq!(lowered.purposes(), [Purpose::WasmJit]);
            assert!(!lowered
                .nodes
                .iter()
                .flat_map(|n| &n.ops)
                .any(|op| matches!(op, Op::Word(_) | Op::Directive(_))));
            let mut ops = vec![Op::La {
                rd: SP,
                addr: Addr::StacksEnd,
            }];
            for (i, arg) in args.iter().enumerate() {
                ops.push(Op::Li {
                    rd: A0 + i as u32,
                    imm: i64::from(*arg),
                });
            }
            ops.extend([
                Op::Jal {
                    rd: RA,
                    to: symbol.into(),
                },
                Op::La {
                    rd: T2,
                    addr: Addr::StacksEnd,
                },
                Op::Bne {
                    rs1: SP,
                    rs2: T2,
                    to: "failed".into(),
                },
                Op::Li {
                    rd: T0,
                    imm: i64::from(expected),
                },
                Op::Sw {
                    rs2: T0,
                    rs1: SP,
                    off: -4,
                },
                Op::Lw {
                    rd: T0,
                    rs: SP,
                    off: -4,
                },
                Op::Bne {
                    rs1: A0,
                    rs2: T0,
                    to: "failed".into(),
                },
                Op::Li {
                    rd: A0,
                    imm: i64::from(b'P'),
                },
                Op::Jal {
                    rd: X0,
                    to: "report".into(),
                },
                Op::Label("failed".into()),
                Op::Li {
                    rd: A0,
                    imm: i64::from(b'F'),
                },
                Op::Label("report".into()),
                Op::Li { rd: A7, imm: 1 },
                Op::Ecall,
                Op::Wfi,
            ]);
            lowered.nodes.insert(
                0,
                Node {
                    purpose: Purpose::WasmJit,
                    ops,
                },
            );
            let smoke = exec::run_module(spec, &lowered, 0x0001_0000).unwrap();
            assert_eq!(
                smoke.halt,
                exec::Halt::Wfi,
                "xlen={xlen} steps={} asm={}",
                smoke.steps,
                lowered.to_asm()
            );
            assert_eq!(
                smoke.console, "P",
                "xlen={xlen} expected={expected} args={args:?}"
            );
        };
        let spec = Default::default();
        execute(&spec, 64);
        let mut spec32 = spec.clone();
        spec32.isa.xlen = 32;
        execute(&spec32, 32);
    }

    #[test]
    fn numeric_exports_execute_machine_words_on_both_xlens() {
        for opcode in [0x6a, 0x6b, 0x6c, 0x73, 0x46, 0x47] {
            let bytes = numeric(2, 1, 0, &[0x20, 0, 0x20, 1, opcode, 0x0b]);
            for args in [
                [1, 2],
                [i32::MAX, 1],
                [i32::MIN, -1],
                [-1, -1],
                [0, 0],
                [65_536, 65_536],
            ] {
                differential(&bytes, &args);
            }
        }
        differential(
            &numeric(1, 1, 1, &[0x20, 0, 0x22, 1, 0x20, 1, 0x6c, 0x0b]),
            &[7],
        );
        differential(&numeric(0, 1, 1, &[0x20, 0, 0x0b]), &[]);
        differential(
            &numeric(0, 1, 0, &[0x41, 0xff, 0xff, 0xff, 0xff, 7, 0x0b]),
            &[],
        );
        for arg in [0, 1, -1] {
            differential(&numeric(1, 1, 0, &[0x20, 0, 0x45, 0x0b]), &[arg]);
            differential(
                &numeric(1, 1, 0, &[0x41, 7, 0x41, 9, 0x20, 0, 0x1b, 0x0b]),
                &[arg],
            );
        }
        differential(&numeric(0, 1, 0, &[0x41, 11, 0x41, 7, 0x0f, 0x0b]), &[]);
    }

    #[test]
    fn bitwise_shifts_rotates_and_ordering_match_on_both_xlens() {
        let boundaries = [
            0,
            1,
            -1,
            i32::MIN,
            i32::MAX,
            0x5555_5555,
            0xaaaa_aaaau32 as i32,
        ];
        for opcode in [0x71, 0x72, 0x48, 0x49, 0x4a, 0x4b, 0x4c, 0x4d, 0x4e, 0x4f] {
            let bytes = numeric(2, 1, 0, &[0x20, 0, 0x20, 1, opcode, 0x0b]);
            for a in boundaries {
                for b in boundaries {
                    differential(&bytes, &[a, b]);
                }
            }
        }
        for opcode in [0x74, 0x75, 0x76, 0x77, 0x78] {
            let bytes = numeric(2, 1, 0, &[0x20, 0, 0x20, 1, opcode, 0x0b]);
            for a in boundaries {
                for shift in [0, 1, 7, 16, 31, 32, 33, 63, 64, -1, i32::MIN] {
                    differential(&bytes, &[a, shift]);
                }
            }
        }
        let mut seed = 0x6a09_e667u32;
        for opcode in [
            0x71, 0x72, 0x74, 0x75, 0x76, 0x77, 0x78, 0x48, 0x49, 0x4a, 0x4b, 0x4c, 0x4d, 0x4e,
            0x4f,
        ] {
            let bytes = numeric(2, 1, 0, &[0x20, 0, 0x20, 1, opcode, 0x0b]);
            for _ in 0..32 {
                seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
                let a = seed as i32;
                seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
                differential(&bytes, &[a, seed as i32]);
            }
        }
        for args in [[i32::MIN, -1, 31], [1, 0, 32], [i32::MAX, 0x5555_5555, -1]] {
            differential(
                &numeric(
                    3,
                    1,
                    1,
                    &[
                        0x20, 0, 0x20, 1, 0x72, 0x22, 3, 0x20, 2, 0x76, 0x20, 3, 0x20, 2, 0x77,
                        0x71, 0x20, 0, 0x4d, 0x0b,
                    ],
                ),
                &args,
            );
        }
    }

    #[test]
    fn compatibility_add_facade_wraps_i32() {
        let bytes = numeric(2, 1, 0, &[0x20, 0, 0x20, 1, 0x6a, 0x0b]);
        check_numeric(&bytes, &[i32::MAX, 1], true);
        check_numeric(&bytes, &[i32::MIN, -1], true);
    }

    #[test]
    fn unsupported_exports_fail_closed() {
        for ops in [
            &[0x3f, 0, 0x0b][..],
            &[0x41, 0, 0x28, 2, 0, 0x0b],
            &[0x41, 1, 0x40, 0, 0x0b],
        ] {
            let bytes = crate::binary::tests::numeric_with_memory(0, 1, 0, ops, Some((1, Some(2))));
            let m = decode(&bytes).unwrap();
            for xlen in [32, 64] {
                assert!(jit_riscv(&m, "main", xlen).is_err());
            }
        }
        let m = decode(&numeric(0, 1, 0, &[0x41, 7, 0x0b])).unwrap();
        assert!(jit_riscv(&m, "missing", 64).is_err());
        assert!(jit_riscv(&m, "main", 16).is_err());
        let m = decode(&numeric(0, 0, 0, &[0x03, 0x40, 0x0c, 0, 0x0b, 0x0b])).unwrap();
        assert!(jit_riscv(&m, "main", 64).is_err());
        let m = decode(&numeric(2, 1, 0, &[0x20, 0, 0x20, 1, 0x6d, 0x0b])).unwrap();
        assert!(jit_riscv(&m, "main", 64).is_err());
        let m = decode(crate::BIOS_UI_WASM).unwrap();
        assert!(jit_riscv(&m, "_start", 64).is_err());
        let m = decode(&numeric(4, 1, 0, &[0x20, 0, 0x0b])).unwrap();
        assert!(jit_riscv(&m, "main", 64).is_err());
        let m = decode(&numeric(3, 1, 253, &[0x20, 0, 0x0b])).unwrap();
        assert!(jit_riscv(&m, "main", 64).is_err());
        let mut m = decode(&numeric(0, 1, 0, &[0x41, 7, 0x0b])).unwrap();
        m.exports[0].name = "main\nmalicious".into();
        assert!(jit_riscv(&m, "main\nmalicious", 64).is_err());
        let mut ops = vec![0x01; MAX_JIT_INSTRUCTIONS];
        ops.push(0x0b);
        let m = decode(&numeric(0, 0, 0, &ops)).unwrap();
        assert!(jit_riscv(&m, "main", 64).is_err());
    }

    /// Guest `_start` lowering: `i32.const` + `env` calls → `WasmStart`,
    /// executed against the real `g6b-asm::dom` stubs on both xlens.
    #[test]
    fn start_ops_executes_dom_imports_in_guest_ir() {
        let bytes = crate::encode_ui_module("status", "UI-BOOT");
        let wm = decode(&bytes).unwrap();
        for xlen in [64, 32] {
            let spec = g6b_spec::BoardSpec::from_json_str(&format!(
                r#"{{"schema_version":1,"isa":{{"xlen":{xlen}}},"kernel":{{"wasm":{{"enable":true,"jit":true}}}}}}"#
            ))
            .unwrap();
            let ops = start_ops(&wm, xlen).unwrap();
            let mut m = Module {
                nharts: 1,
                line_bytes: g6b_asm::UART_LINE_BSS,
                ui_bytes: g6b_asm::UI_HEADER_BYTES,
                wasm_data: data_image(&wm).unwrap(),
                ..Default::default()
            };
            g6b_asm::dom::attach(&mut m, &spec);
            let mut merged = false;
            for n in &mut m.nodes {
                if n.ops
                    .iter()
                    .any(|o| matches!(o, Op::Label(l) if l == "WasmStart"))
                {
                    n.ops = ops.clone();
                    merged = true;
                }
            }
            assert!(merged, "WasmStart anchor");
            m.nodes.insert(
                0,
                Node {
                    purpose: Purpose::WasmJit,
                    ops: vec![
                        Op::La {
                            rd: SP,
                            addr: Addr::StacksEnd,
                        },
                        Op::Jal {
                            rd: RA,
                            to: "WasmUi".into(),
                        },
                        Op::Wfi,
                    ],
                },
            );
            let smoke = exec::run_module(&spec, &m, 0x0001_0000).unwrap();
            assert_eq!(
                smoke.halt,
                exec::Halt::Wfi,
                "xlen={xlen} asm={}",
                m.to_asm()
            );
            assert_eq!(smoke.dom_rows, 1, "xlen={xlen}");
            assert_eq!(smoke.console, "DOM| UI-BOOT\n", "xlen={xlen}");
        }
    }

    #[test]
    fn start_ops_fail_closed() {
        let wm = decode(&crate::encode_ui_module("status", "UI-BOOT")).unwrap();
        assert!(start_ops(&wm, 16).is_err());
        let mut m = wm.clone();
        m.bodies[0] = vec![crate::Instr::Call(9), crate::Instr::End];
        assert!(start_ops(&m, 64).is_err(), "non-import call must fail");
        let mut m = wm.clone();
        m.bodies[0] = vec![
            crate::Instr::I32Const(0),
            crate::Instr::Call(0),
            crate::Instr::Nop,
            crate::Instr::End,
        ];
        assert!(start_ops(&m, 64).is_err(), "non-straight-line must fail");
        let mut m = wm.clone();
        m.bodies[0] = vec![crate::Instr::I32Const(0), crate::Instr::End];
        assert!(start_ops(&m, 64).is_err(), "leftover operand must fail");
        let m = decode(&numeric(0, 1, 0, &[0x41, 7, 0x0b])).unwrap();
        assert!(start_ops(&m, 64).is_err(), "no _start export must fail");
    }

    #[test]
    fn data_image_trims_to_data_content() {
        let wm = decode(&crate::encode_ui_module("status", "UI-BOOT")).unwrap();
        let img = data_image(&wm).unwrap();
        assert!(img.len() <= MAX_WASM_DATA);
        assert!(img.windows(7).any(|w| w == b"UI-BOOT"));
    }
}
