// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Lower a WASM i32.add export to RISC-V (`g6b-asm`).

#![allow(missing_docs)]

use g6b_asm::encode::{A0, A1, RA, X0};
use g6b_asm::{Module, Node, Op, Purpose};

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
            Op::Add {
                rd: A0,
                rs1: A0,
                rs2: A1,
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
