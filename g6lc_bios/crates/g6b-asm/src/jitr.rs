// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
//! `jitr` — the **guest** JIT: emitted `g6b-asm` routines that read the
//! predecoded `__jit_in` image (`g6b_wasm::jcode`), emit RISC-V machine code
//! into `__jit_code`, `fence.i`, then `jalr` into it — all inside the S-mode
//! payload, with no host participation after the ELF is built.
//!
//! Execution model (RV64):
//!
//! ```text
//! s8  = __wasm_mem   linear-memory base (data image copied in at JitRun)
//! s9  = __jit        state header + save area + function table + globals
//! s10 = wasm value-stack pointer (8-byte cells, grows up)
//! s11 = frame base — locals[i] at 8*i(s11); params sit below the stack base
//! s4..s7 are translator state only: jit_in, code base, cursor, func slot0.
//! ```
//!
//! Generated code is a sequence of 32-word (128-byte) slots, one per jcode
//! record; `JMP`/`JZ`/`JNZ` targets are absolute addresses materialised as
//! `lui`+`addiw`+`slli`+`srli` + `jalr`, so no in-guest B/J-immediate packing
//! is needed — every emitted word is either a host-computed constant
//! (`encode::*` baked into the translator) or an `li` of a runtime address.
//!
//! Provenance rule: this is what makes "guest ran the cell" true. The
//! displayed/returned value comes out of `__jit`+`__wasm_mem`, never the
//! host `GuestWebPresent` path.
//!
//! ```text
//! __jit header (u64 slots):
//!   +0   magic 'G6JT' | +8 state | +16 fuel | +24 code_len | +32 err
//!   +40  result       | +48 mem_bytes | +56 rec_base      | +64..+128 save[8]
//!   +128 code_end     | +136 ftab[256] | +2184 glob[128]  → 8192 B
//!   +96 bc_off  +104 nres   (translator scratch inside save[8])
//! ```

use crate::jfmt as jc;

use crate::encode::{
    A0, A1, A2, A3, A4, A5, A6, A7, RA, S0, S1, S10, S11, S2, S3, S4, S5, S6, S7, S8, S9,
    SBI_PUTCHAR, SP, T0, T1, T2, T3, T4, T5, T6, TP, X0,
};
use crate::{encode, Addr, Module, Node, Op, Purpose};

// ---- __jit header offsets -------------------------------------------------
pub const JIT_MAGIC: u64 = 0x544A_3647; // "G6JT" LE
pub const OFF_MAGIC: i32 = 0;
pub const OFF_STATE: i32 = 8;
pub const OFF_FUEL: i32 = 16;
pub const OFF_CODELEN: i32 = 24;
pub const OFF_ERR: i32 = 32;
pub const OFF_RESULT: i32 = 40;
pub const OFF_MEMB: i32 = 48;
pub const OFF_RECB: i32 = 56;
pub const OFF_SAVE: i32 = 64; // 8 u64 slots → ends 128
pub const OFF_BCOFF: i32 = OFF_SAVE + 32; // +96  translator scratch
pub const OFF_NRES: i32 = OFF_SAVE + 40; //  +104 translator scratch
pub const OFF_CODE_END: i32 = 128;
pub const OFF_FTAB: i32 = 136; // 256 × u64 → ends 2184
pub const OFF_GLOB: i32 = OFF_FTAB + 256 * 8; // 128 × u64 → ends 3208
                                              // M3 call_indirect table descriptors (parsed from the `__jit_in` trailer).
                                              // These reuse the free `save[8]` slots so plain 12-bit `ld`/`sd` reach them.
pub const OFF_NTBL: i32 = OFF_SAVE + 8; //  +72   funcref-table length
pub const OFF_SIGB: i32 = OFF_SAVE + 48; // +112  sig[] base (__jit_in)
pub const OFF_TBLB: i32 = OFF_SAVE + 56; // +120  tbl[] base (__jit_in)
                                         // Re-entry state (Stage 3) — sits in the free tail of the 8192-byte header.
/// `__jit_in` address of the AX (asyncify/listener funcidx) trailer, 0 = absent.
pub const OFF_AXB: i32 = OFF_GLOB + 128 * 8; // 3208
/// Trap continuation: the `jalr` target `jit_trap` jumps to after printing —
/// `jit_after` for `JitRun`, `jit_call_done` for `JitCall`.
pub const OFF_RESUME: i32 = OFF_AXB + 8; // 3216
/// Saved `sp` at the top-level call — `jit_trap` restores it so a fault deep in
/// a generated-call nest unwinds to the right frame instead of corrupting the
/// caller's register reload.
pub const OFF_SPSAVE: i32 = OFF_RESUME + 8; // 3224
pub const JIT_HDR_BYTES: u64 = 8192;

const STATE_XLATE: i64 = 1;
const STATE_OK: i64 = 2;
const STATE_TRAP: i64 = 3;

/// One 32-word (128-byte) slot per jcode record — largest recipe is ~30.
pub const SLOT_WORDS: u64 = 32;
pub const SLOT_BYTES: u64 = SLOT_WORDS * 4;
const SLOT_LG2: u32 = 7;

/// Generated calls decrement fuel; zero → `WASM-JIT-TRAP 7`.
const FUEL: i64 = 1 << 20;
const R_OP_COUNT: i64 = jc::R_OP_COUNT as i64;

// ---- small op helpers -----------------------------------------------------
fn ld(rd: u32, rs: u32, off: i32) -> Op {
    Op::Ld { rd, rs, off }
}
fn sd(rs2: u32, rs1: u32, off: i32) -> Op {
    Op::Sd { rs2, rs1, off }
}
fn lw(rd: u32, rs: u32, off: i32) -> Op {
    Op::Lw { rd, rs, off }
}
fn lbu(rd: u32, rs: u32, off: i32) -> Op {
    Op::Lbu { rd, rs, off }
}
fn sb(rs2: u32, rs: u32, off: i32) -> Op {
    Op::Sb { rs2, rs1: rs, off }
}
fn addi(rd: u32, rs: u32, imm: i32) -> Op {
    Op::Addi { rd, rs, imm }
}
fn add(rd: u32, a: u32, b: u32) -> Op {
    Op::Add { rd, rs1: a, rs2: b }
}
fn sub(rd: u32, a: u32, b: u32) -> Op {
    Op::Sub { rd, rs1: a, rs2: b }
}
fn and_(rd: u32, a: u32, b: u32) -> Op {
    Op::And { rd, rs: a, rs2: b }
}
fn or_(rd: u32, a: u32, b: u32) -> Op {
    Op::Or { rd, rs: a, rs2: b }
}
fn slli(rd: u32, rs: u32, shamt: u32) -> Op {
    Op::Slli { rd, rs, shamt }
}
fn srli(rd: u32, rs: u32, shamt: u32) -> Op {
    Op::Srli { rd, rs, shamt }
}
fn srai(rd: u32, rs: u32, shamt: u32) -> Op {
    Op::Srai { rd, rs, shamt }
}
fn li(rd: u32, imm: i64) -> Op {
    Op::Li { rd, imm }
}
fn la(rd: u32, addr: Addr) -> Op {
    Op::La { rd, addr }
}
fn mv(rd: u32, rs: u32) -> Op {
    addi(rd, rs, 0)
}
fn beq(a: u32, b: u32, to: &str) -> Op {
    Op::Beq {
        rs1: a,
        rs2: b,
        to: to.into(),
    }
}
fn bne(a: u32, b: u32, to: &str) -> Op {
    Op::Bne {
        rs1: a,
        rs2: b,
        to: to.into(),
    }
}
fn bltu(a: u32, b: u32, to: &str) -> Op {
    Op::Bltu {
        rs1: a,
        rs2: b,
        to: to.into(),
    }
}
fn bgeu(a: u32, b: u32, to: &str) -> Op {
    Op::Bgeu {
        rs1: a,
        rs2: b,
        to: to.into(),
    }
}
fn jal(to: &str) -> Op {
    Op::Jal {
        rd: RA,
        to: to.into(),
    }
}
fn j(to: &str) -> Op {
    Op::Jal {
        rd: X0,
        to: to.into(),
    }
}
fn ret() -> Op {
    Op::Jalr {
        rd: X0,
        rs: RA,
        imm: 0,
    }
}
fn putc(ops: &mut Vec<Op>, ch: i64) {
    ops.extend([li(A0, ch), li(A7, SBI_PUTCHAR), Op::Ecall]);
}
fn puts(ops: &mut Vec<Op>, s: &str) {
    for b in s.bytes() {
        putc(ops, i64::from(b));
    }
}
/// Print `T0` as 16 hex digits via the shared `hexdig` table (trap node).
fn put_hex(ops: &mut Vec<Op>, label: &str) {
    ops.extend([
        li(A2, 16),
        Op::Label(label.into()),
        srli(T2, T0, 60),
        Op::Andi {
            rd: T2,
            rs: T2,
            imm: 0xf,
        },
        slli(T0, T0, 4),
        la(A6, Addr::Label("hexdig".into())),
        add(A6, A6, T2),
        lbu(A0, A6, 0),
        li(A7, SBI_PUTCHAR),
        Op::Ecall,
        addi(A2, A2, -1),
        bne(A2, X0, label),
    ]);
}

// ---- emit-call helpers (inside the translator) ----------------------------
/// Emit one constant machine word (`encode::*` computed host-side).
fn emw(ops: &mut Vec<Op>, word: u32) {
    ops.extend([li(A0, i64::from(word)), jal("jit_em")]);
}
/// Emit an I-type word: template | (imm & 0xfff) << 20. `imm` is a
/// translator register holding the immediate value.
fn emi(ops: &mut Vec<Op>, tmpl: u32, imm_reg: u32) {
    ops.extend([li(A0, i64::from(tmpl)), mv(A1, imm_reg), jal("jit_emi")]);
}
/// Emit an S-type word: template | (imm&0x1f)<<7 | (imm&0xfe0)<<20.
fn ems(ops: &mut Vec<Op>, tmpl: u32, imm_reg: u32) {
    ops.extend([li(A0, i64::from(tmpl)), mv(A1, imm_reg), jal("jit_ems")]);
}
/// Emit `lui rd,HI; addiw rd,rd,LO; slli rd,rd,32; srli rd,rd,32` — a
/// zero-extended 32-bit-range absolute load (4 words). `val` is a translator
/// register holding the value.
fn em64(ops: &mut Vec<Op>, rd: u32, val_reg: u32) {
    ops.extend([li(A0, i64::from(rd)), mv(A1, val_reg), jal("jit_lia")]);
}
/// Emit `li a0, code; li t6, jit_trap; jalr x0,t6,0` — a generated trap
/// (6 words; forward skip-branches elsewhere assume exactly this length).
fn em_trap(ops: &mut Vec<Op>, code: i64, tmp: u32) {
    ops.push(li(tmp, code));
    emi(ops, encode::addi(A0, X0, 0), tmp);
    ops.extend([la(A0, Addr::Label("jit_trap".into())), jal("jit_lia_t6")]);
    emw(ops, encode::jalr(X0, T6, 0));
}

// ===========================================================================
// jit_em / jit_emi / jit_lia — the emit primitives
// ===========================================================================

/// `jit_em`: write `a0` at the cursor `s6`, advance 4. Bounds-checked against
/// the code-arena end; overflow → `jit_trap` (XLATE).
fn jit_em_node() -> Vec<Op> {
    vec![
        Op::Comment("jit_em — emit one machine word at s6 (arena bounds-checked)".into()),
        Op::Label("jit_em".into()),
        ld(T0, S9, OFF_CODE_END),
        bgeu(S6, T0, "jit_em_ovf"),
        Op::Sw {
            rs2: A0,
            rs1: S6,
            off: 0,
        },
        addi(S6, S6, 4),
        ret(),
        Op::Label("jit_em_ovf".into()),
        li(A0, b'E' as i64),
        li(A7, SBI_PUTCHAR),
        Op::Ecall,
        li(A0, i64::from(jc::TRAP_XLATE)),
        mv(A1, S6), // aux = cursor
        j("jit_trap"),
    ]
}

/// `jit_emi`: emit `a0 | (a1 & 0xfff) << 20` — one I-type word with a
/// translate-time immediate (two's-complement 12-bit).
fn jit_emi_node() -> Vec<Op> {
    vec![
        Op::Comment("jit_emi — emit an I-type word: template | (imm&0xfff)<<20".into()),
        Op::Label("jit_emi".into()),
        li(T1, 0xfff),
        and_(T0, A1, T1),
        slli(T0, T0, 20),
        or_(A0, A0, T0),
        j("jit_em"),
    ]
}

/// `jit_ems`: emit `a0 | (a1&0x1f)<<7 | (a1&0xfe0)<<20` — one S-type word
/// with a translate-time immediate in `a1` (the split store encoding —
/// patching a store with the I-type field would smash rs2 instead).
fn jit_ems_node() -> Vec<Op> {
    vec![
        Op::Comment(
            "jit_ems — emit an S-type word: template | (imm&0x1f)<<7 | (imm&0xfe0)<<20".into(),
        ),
        Op::Label("jit_ems".into()),
        li(T1, 0x1f),
        and_(T0, A1, T1),
        slli(T0, T0, 7),
        or_(A0, A0, T0),
        li(T1, 0xfe0),
        and_(T0, A1, T1),
        slli(T0, T0, 20),
        or_(A0, A0, T0),
        j("jit_em"),
    ]
}

/// `jit_lia`: emit a 4-word absolute `li` of the 32-bit value in `a1` into
/// `a0`: `lui rd,HI; addiw rd,rd,LO; slli rd,rd,32; srli rd,rd,32`.
/// This is the only place an emitted instruction's fields are built at
/// translate time — QEMU DRAM base 0x8000_0000 must not sign-extend.
fn jit_lia_node() -> Vec<Op> {
    vec![
        Op::Comment("jit_lia — emit absolute li (4w): a0=rd, a1=value".into()),
        Op::Label("jit_lia".into()),
        addi(SP, SP, -16),
        sd(RA, SP, 8),
        mv(T4, A0), // rd
        mv(T5, A1), // value
        // HI = (v + 0x800) >> 12 (logical, v < 2^32)
        li(T0, 0x800),
        add(T0, T5, T0),
        srli(T0, T0, 12),
        li(T1, 0xf_ffff),
        and_(T0, T0, T1),
        // word = (HI << 12) | (rd << 7) | 0x37  (lui)
        slli(T0, T0, 12),
        slli(T1, T4, 7),
        or_(T0, T0, T1),
        li(T1, 0x37),
        or_(A0, T0, T1),
        jal("jit_em"),
        // LO = sext12(v)
        slli(T0, T5, 52),
        srai(T0, T0, 52),
        mv(A1, T0),
        // addiw rd,rd,LO = (rd<<15)|(rd<<7)|0x1b
        slli(T0, T4, 15),
        slli(T1, T4, 7),
        or_(T0, T0, T1),
        li(T1, 0x1b),
        or_(A0, T0, T1),
        jal("jit_emi"),
        // slli rd,rd,32 = (32<<20)|(rd<<15)|(1<<12)|(rd<<7)|0x13
        li(T0, 0x0200_1013),
        slli(T1, T4, 15),
        or_(T0, T0, T1),
        slli(T1, T4, 7),
        or_(A0, T0, T1),
        jal("jit_em"),
        // srli rd,rd,32 = (32<<20)|(rd<<15)|(5<<12)|(rd<<7)|0x13
        li(T0, 0x0200_5013),
        slli(T1, T4, 15),
        or_(T0, T0, T1),
        slli(T1, T4, 7),
        or_(A0, T0, T1),
        jal("jit_em"),
        ld(RA, SP, 8),
        addi(SP, SP, 16),
        ret(),
        // jit_lia_t6 / jit_lia_t1 — same with a0 = the address, rd = T6 / T1.
        Op::Label("jit_lia_t6".into()),
        mv(A1, A0),
        li(A0, i64::from(T6)),
        j("jit_lia"),
        Op::Label("jit_lia_t1".into()),
        mv(A1, A0),
        li(A0, i64::from(T1)),
        j("jit_lia"),
    ]
}

// ===========================================================================
// Handlers — one per jcode record op. Args:
//   a1 = rec.a   a2 = rec.b   a3 = slot_base(code)   a4 = func slot0(code)
//   a5 = __jit_in   a6 = rec addr(jit_in)   a7 = nresults(func)
// jit_em clobbers a0; jit_emi a0-a1,t0-t1; jit_lia a0-a1,t0-t1,t4,t5.
// Handler scratch: t2,t3 (+t4/t5 only across non-lia calls).
// ===========================================================================

fn h_prologue(ops: &mut Vec<Op>) {
    ops.extend([addi(SP, SP, -16), sd(RA, SP, 8)]);
}
fn h_epilogue(ops: &mut Vec<Op>) {
    ops.extend([ld(RA, SP, 8), addi(SP, SP, 16), ret()]);
}

/// push generated reg `r`: `sd r,0(s10); addi s10,s10,8`
fn em_push(ops: &mut Vec<Op>, r: u32) {
    emw(ops, encode::sd(r, S10, 0));
    emw(ops, encode::addi(S10, S10, 8));
}
/// pop into generated reg `r`: `addi s10,-8; ld r,0(s10)`
fn em_pop(ops: &mut Vec<Op>, r: u32) {
    emw(ops, encode::addi(S10, S10, -8));
    emw(ops, encode::ld(r, S10, 0));
}
/// pop two operands: `addi s10,-16; ld t0,0(s10); ld t1,8(s10)` —
/// the first-pushed (deeper) slot is `t0` = lhs, the top is `t1` = rhs.
fn em_pop2(ops: &mut Vec<Op>) {
    emw(ops, encode::addi(S10, S10, -16));
    emw(ops, encode::ld(T0, S10, 0));
    emw(ops, encode::ld(T1, S10, 8));
}
/// Emit `addi t3, x0, imm` — small constant into generated T3.
fn em_li_t3(ops: &mut Vec<Op>, imm: i64, tmp: u32) {
    ops.push(li(tmp, imm));
    emi(ops, encode::addi(T3, X0, 0), tmp);
}

// ---- FP emit helpers (M3b) --------------------------------------------------
// The exec-model FPU lives in `csr.fr[]`; generated code parks WASM FP operands
// there via fmv and reads results back the same way. `fmtr` is a translator reg
// holding the fmt width bit (0 = f32, 1 = f64) — the OP-FP funct7 low bit.
const F0: u32 = 0; // generated FP scratch regs
const F1: u32 = 1;

/// Emit `fmv.{w|d}.x fp_reg <- int_reg` — int bit-pattern → FP reg (f7=0x78|fmt).
fn em_fmv_i2f(ops: &mut Vec<Op>, fmtr: u32, int_reg: u32, fp_reg: u32) {
    ops.push(li(A0, 0x78));
    ops.push(or_(A0, A0, fmtr));
    ops.push(slli(A0, A0, 25));
    ops.push(li(T1, i64::from((int_reg << 15) | (fp_reg << 7) | 0x53)));
    ops.push(or_(A0, A0, T1));
    ops.push(jal("jit_em"));
}
/// Emit `fmv.x.{w|d} int_reg <- fp_reg` — FP reg → int bit-pattern (f7=0x70|fmt).
fn em_fmv_f2i(ops: &mut Vec<Op>, fmtr: u32, fp_reg: u32, int_reg: u32) {
    ops.push(li(A0, 0x70));
    ops.push(or_(A0, A0, fmtr));
    ops.push(slli(A0, A0, 25));
    ops.push(li(T1, i64::from((fp_reg << 15) | (int_reg << 7) | 0x53)));
    ops.push(or_(A0, A0, T1));
    ops.push(jal("jit_em"));
}
/// Emit `fop rd <- rs1 (f3) rs2` — an OP-FP R-type word. `f7r`/`f3r` are
/// translator regs holding funct7/funct3; rs1/rs2/rd are fixed reg numbers.
fn em_fop(ops: &mut Vec<Op>, f7r: u32, rs2: u32, rs1: u32, f3r: u32, rd: u32) {
    ops.push(slli(A0, f7r, 25));
    ops.push(slli(T1, f3r, 12));
    ops.push(or_(A0, A0, T1));
    ops.push(li(
        T1,
        i64::from((rs2 << 20) | (rs1 << 15) | (rd << 7) | 0x53),
    ));
    ops.push(or_(A0, A0, T1));
    ops.push(jal("jit_em"));
}
/// Same, but `rs2r` is a translator reg holding the rs2 FIELD value (used by
/// fcvt, where rs2 selects the int width/signedness rather than a register).
fn em_fop_r2(ops: &mut Vec<Op>, f7r: u32, rs2r: u32, rs1: u32, f3: u32, rd: u32) {
    ops.push(slli(A0, f7r, 25));
    ops.push(slli(T1, rs2r, 20));
    ops.push(or_(A0, A0, T1));
    ops.push(li(
        T1,
        i64::from((rs1 << 15) | (f3 << 12) | (rd << 7) | 0x53),
    ));
    ops.push(or_(A0, A0, T1));
    ops.push(jal("jit_em"));
}

// ---- trivial handlers -----------------------------------------------------

fn jit_h_nop() -> Vec<Op> {
    vec![Op::Label("jit_h_nop".into()), ret()]
}

/// CONST — `b` lives in the record; emit `li t1,&rec.b; ld t0,0(t1); push`.
fn jit_h_const() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_const".into())];
    h_prologue(&mut ops);
    ops.push(addi(A0, A6, 8));
    ops.push(jal("jit_lia_t1"));
    emw(&mut ops, encode::ld(T0, T1, 0));
    em_push(&mut ops, T0);
    h_epilogue(&mut ops);
    ops
}

/// `lget`/`lset`/`ltee`: the local offset `idx*8` can exceed the 12-bit
/// `ld`/`sd` immediate once a frame has >255 locals (the cell's `_start`
/// uses ~845). Materialise `s11 + idx*8` in `t1` and access at offset 0 —
/// the same full-width idiom the prologue's local-zero loop uses.
fn jit_h_lget() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_lget".into())];
    h_prologue(&mut ops);
    ops.push(slli(A1, A1, 3));
    em64(&mut ops, T1, A1);
    emw(&mut ops, encode::add(T1, S11, T1));
    emw(&mut ops, encode::ld(T0, T1, 0));
    em_push(&mut ops, T0);
    h_epilogue(&mut ops);
    ops
}

fn jit_h_lset() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_lset".into())];
    h_prologue(&mut ops);
    ops.push(slli(A1, A1, 3));
    em64(&mut ops, T1, A1);
    emw(&mut ops, encode::add(T1, S11, T1));
    em_pop(&mut ops, T0);
    emw(&mut ops, encode::sd(T0, T1, 0));
    h_epilogue(&mut ops);
    ops
}

fn jit_h_ltee() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_ltee".into())];
    h_prologue(&mut ops);
    ops.push(slli(A1, A1, 3));
    em64(&mut ops, T1, A1);
    emw(&mut ops, encode::add(T1, S11, T1));
    emw(&mut ops, encode::ld(T0, S10, -8));
    emw(&mut ops, encode::sd(T0, T1, 0));
    h_epilogue(&mut ops);
    ops
}

fn jit_h_drop() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_drop".into())];
    h_prologue(&mut ops);
    emw(&mut ops, encode::addi(S10, S10, -8));
    h_epilogue(&mut ops);
    ops
}

// ---- ALU: pop2 + one pooled op word + push --------------------------------

fn jit_h_alu(name: &str, pool: &str) -> Vec<Op> {
    let mut ops = vec![Op::Label(name.into())];
    h_prologue(&mut ops);
    ops.extend([
        slli(T0, A1, 2),
        la(T2, Addr::Label(pool.into())),
        add(T2, T2, T0),
        lw(T4, T2, 0),
    ]);
    em_pop2(&mut ops);
    ops.push(mv(A0, T4));
    ops.push(jal("jit_em"));
    em_push(&mut ops, T0);
    h_epilogue(&mut ops);
    ops
}

/// Inline `.word` pool reached via a jump-over: `la` to `name` works.
fn word_pool(ops: &mut Vec<Op>, name: &str, words: &[u32]) {
    ops.push(j(&format!("{name}_over")));
    ops.push(Op::Label(name.into()));
    for w in words {
        ops.push(Op::Word(*w));
    }
    ops.push(Op::Label(format!("{name}_over")));
}

// ---- CMP: recipe pool, 8 words per entry, 0-terminated --------------------

fn jit_h_cmp() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_cmp".into())];
    h_prologue(&mut ops);
    // t4 = jit_cmp_recipes + a1*32
    ops.extend([
        slli(T0, A1, 5),
        la(T2, Addr::Label("jit_cmp_recipes".into())),
    ]);
    ops.push(add(T4, T2, T0));
    // subops >= 20 (eqz) pop one operand
    ops.extend([li(T0, 20), bltu(A1, T0, "jit_cmp_pop2")]);
    em_pop(&mut ops, T0);
    ops.push(j("jit_cmp_emit"));
    ops.push(Op::Label("jit_cmp_pop2".into()));
    em_pop2(&mut ops);
    ops.extend([
        Op::Label("jit_cmp_emit".into()),
        Op::Label("jit_cmp_rec".into()),
        lw(A0, T4, 0),
        beq(A0, X0, "jit_cmp_done"),
        jal("jit_em"),
        addi(T4, T4, 4),
        j("jit_cmp_rec"),
        Op::Label("jit_cmp_done".into()),
    ]);
    em_push(&mut ops, T0);
    h_epilogue(&mut ops);
    ops
}

// ---- control flow: absolute targets via jit_lia into T6 + jalr ------------

/// slot addr of record `a1` (function-relative) = `a4` (func slot0) + a1*SLOT.
fn slot_target(ops: &mut Vec<Op>) {
    ops.extend([slli(T0, A1, SLOT_LG2), add(A0, A4, T0), jal("jit_lia_t6")]);
}

fn jit_h_jmp() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_jmp".into())];
    h_prologue(&mut ops);
    slot_target(&mut ops);
    emw(&mut ops, encode::jalr(X0, T6, 0));
    h_epilogue(&mut ops);
    ops
}

/// JZ: pop; `bne t0,x0,+24` skips the 6-word jump (4w lia + jalr).
fn jit_h_jz() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_jz".into())];
    h_prologue(&mut ops);
    em_pop(&mut ops, T0);
    emw(&mut ops, encode::bne(T0, X0, 24));
    slot_target(&mut ops);
    emw(&mut ops, encode::jalr(X0, T6, 0));
    h_epilogue(&mut ops);
    ops
}

fn jit_h_jnz() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_jnz".into())];
    h_prologue(&mut ops);
    em_pop(&mut ops, T0);
    emw(&mut ops, encode::beq(T0, X0, 24));
    slot_target(&mut ops);
    emw(&mut ops, encode::jalr(X0, T6, 0));
    h_epilogue(&mut ops);
    ops
}

/// RET: move `nres` (a7) results vsp[-nres..] → frame base, pop the frame,
/// restore ra/s11, `jalr x0, ra`.
fn jit_h_ret() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_ret".into())];
    h_prologue(&mut ops);
    ops.extend([
        mv(T4, X0),
        Op::Label("jit_ret_loop".into()),
        bgeu(T4, A7, "jit_ret_done"),
        // src off = -8*(nres - i)
        sub(T5, A7, T4),
        slli(T5, T5, 3),
        sub(T5, X0, T5),
    ]);
    emi(&mut ops, encode::ld(T0, S10, 0), T5);
    ops.push(slli(T5, T4, 3)); // dst off = i*8
    ems(&mut ops, encode::sd(T0, S11, 0), T5);
    ops.extend([
        addi(T4, T4, 1),
        j("jit_ret_loop"),
        Op::Label("jit_ret_done".into()),
    ]);
    // s10 = s11 + nres*8
    ops.extend([slli(T5, A7, 3), mv(A1, T5)]);
    emi(&mut ops, encode::addi(T0, X0, 0), A1);
    emw(&mut ops, encode::add(S10, S11, T0));
    emw(&mut ops, encode::ld(RA, SP, 8));
    emw(&mut ops, encode::ld(S11, SP, 0));
    emw(&mut ops, encode::addi(SP, SP, 16));
    emw(&mut ops, encode::jalr(X0, RA, 0));
    h_epilogue(&mut ops);
    ops
}

// ---- CALL: fuel--, ftab lookup, jalr ----------------------------------------

fn jit_h_call() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_call".into())];
    h_prologue(&mut ops);
    ops.push(mv(T6, A1)); // em_trap clobbers a1 — keep the funcidx
                          // emit: ld t0,FUEL(s9); bne t0,x0,+24; trap(FUEL); addi t0,-1; sd
    emw(&mut ops, encode::ld(T0, S9, OFF_FUEL));
    emw(&mut ops, encode::bne(T0, X0, 28));
    em_trap(&mut ops, i64::from(jc::TRAP_FUEL), T0);
    emw(&mut ops, encode::addi(T0, T0, -1));
    emw(&mut ops, encode::sd(T0, S9, OFF_FUEL));
    // callee addr = ftab[fidx]: li t1, FTAB+fidx*8; add t1,s9; ld t6,0(t1); jalr
    ops.extend([slli(T0, T6, 3), addi(T0, T0, OFF_FTAB)]);
    ops.push(mv(A0, T0));
    ops.push(jal("jit_lia_t1"));
    emw(&mut ops, encode::add(T1, S9, T1));
    emw(&mut ops, encode::ld(T6, T1, 0));
    emw(&mut ops, encode::jalr(RA, T6, 0));
    h_epilogue(&mut ops);
    ops
}

// ---- LOAD / STORE -----------------------------------------------------------

/// OOB check: generated `t3` = bound (addr+off+size); `ld t1,MEMB(s9)`;
/// `bltu t3,t1,+24; trap(OOB)`. The access address itself is not clobbered.
fn emit_oob(ops: &mut Vec<Op>) {
    emw(ops, encode::ld(T1, S9, OFF_MEMB));
    emw(ops, encode::bltu(T3, T1, 28));
    em_trap(ops, i64::from(jc::TRAP_OOB), T0);
}

fn jit_h_load() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_load".into())];
    h_prologue(&mut ops);
    ops.push(mv(T6, A1)); // em64 clobbers a1 — keep the size|sign field
    em_pop(&mut ops, T0);
    // translator t3 = (a1>>1) + a2 = static offset + access size
    ops.extend([srli(T3, A1, 1), add(T3, T3, A2)]);
    em64(&mut ops, T1, T3); // li t1, off+size
    emw(&mut ops, encode::add(T3, T0, T1)); // generated t3 = bound
    emit_oob(&mut ops);
    em64(&mut ops, T1, A2); // li t1, off (a2 = rec.b survives emit calls)
    emw(&mut ops, encode::add(T0, T0, T1));
    emw(&mut ops, encode::add(T0, S8, T0));
    // pick the load word by a1 = (size<<1)|sign
    for (v, l) in [
        (4 << 1, "jit_ld_w"),
        (8 << 1, "jit_ld_d"),
        ((1 << 1) | 1, "jit_ld_b"),
        (1 << 1, "jit_ld_bu"),
        ((2 << 1) | 1, "jit_ld_h"),
        (2 << 1, "jit_ld_hu"),
        ((4 << 1) | 1, "jit_ld_wu"),
    ] {
        ops.extend([li(T0, v), beq(T6, T0, l)]);
    }
    em_trap(&mut ops, i64::from(jc::TRAP_UNSUP), T0);
    ops.push(j("jit_ld_out"));
    for (l, w) in [
        ("jit_ld_w", encode::lw(T2, T0, 0)),
        ("jit_ld_d", encode::ld(T2, T0, 0)),
        ("jit_ld_b", encode::lb(T2, T0, 0)),
        ("jit_ld_bu", encode::lbu(T2, T0, 0)),
        ("jit_ld_h", encode::lh(T2, T0, 0)),
        ("jit_ld_hu", encode::lhu(T2, T0, 0)),
        ("jit_ld_wu", encode::lwu(T2, T0, 0)),
    ] {
        ops.push(Op::Label(l.into()));
        emw(&mut ops, w);
        ops.push(j("jit_ld_out"));
    }
    ops.push(Op::Label("jit_ld_out".into()));
    em_push(&mut ops, T2);
    h_epilogue(&mut ops);
    ops
}

fn jit_h_store() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_store".into())];
    h_prologue(&mut ops);
    ops.push(mv(T6, A1)); // size field survives em64
                          // pop val t2 then addr t0
    emw(&mut ops, encode::addi(S10, S10, -16));
    emw(&mut ops, encode::ld(T2, S10, 8));
    emw(&mut ops, encode::ld(T0, S10, 0));
    ops.push(add(T3, A2, A1)); // offset + size
    em64(&mut ops, T1, T3);
    emw(&mut ops, encode::add(T3, T0, T1)); // generated t3 = bound
    emit_oob(&mut ops);
    em64(&mut ops, T1, A2); // li t1, off
    emw(&mut ops, encode::add(T0, T0, T1));
    emw(&mut ops, encode::add(T0, S8, T0));
    for (v, l) in [
        (4, "jit_st_w"),
        (8, "jit_st_d"),
        (1, "jit_st_b"),
        (2, "jit_st_h"),
    ] {
        ops.extend([li(T0, v), beq(T6, T0, l)]);
    }
    em_trap(&mut ops, i64::from(jc::TRAP_UNSUP), T0);
    ops.push(j("jit_st_out"));
    for (l, w) in [
        ("jit_st_w", encode::sw(T2, T0, 0)),
        ("jit_st_d", encode::sd(T2, T0, 0)),
        ("jit_st_b", encode::sb(T2, T0, 0)),
        ("jit_st_h", encode::sh(T2, T0, 0)),
    ] {
        ops.push(Op::Label(l.into()));
        emw(&mut ops, w);
        ops.push(j("jit_st_out"));
    }
    ops.push(Op::Label("jit_st_out".into()));
    h_epilogue(&mut ops);
    ops
}

// ---- globals / memory / select / div / rot / ext / trap ----------------------

fn jit_h_gget() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_gget".into())];
    h_prologue(&mut ops);
    ops.extend([slli(T3, A1, 3), li(T0, OFF_GLOB as i64), add(T3, T3, T0)]);
    em64(&mut ops, T1, T3);
    emw(&mut ops, encode::add(T1, S9, T1));
    emw(&mut ops, encode::ld(T0, T1, 0));
    em_push(&mut ops, T0);
    h_epilogue(&mut ops);
    ops
}

fn jit_h_gset() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_gset".into())];
    h_prologue(&mut ops);
    ops.extend([slli(T3, A1, 3), li(T0, OFF_GLOB as i64), add(T3, T3, T0)]);
    em64(&mut ops, T1, T3);
    emw(&mut ops, encode::add(T1, S9, T1));
    em_pop(&mut ops, T0);
    emw(&mut ops, encode::sd(T0, T1, 0));
    h_epilogue(&mut ops);
    ops
}

fn jit_h_memsize() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_memsize".into())];
    h_prologue(&mut ops);
    // `memory.size` reports the cell's *declared* pages (`__jit_in`), not the
    // `OFF_MEMB` OOB bound — the `__kget` string pool + asyncify scratch past
    // `mem_pages` are ours, so the cell's `memory.size`-driven heap bound must
    // not grow into them. Read translate-time from `s4` (= `__jit_in`).
    ops.extend([lw(T3, S4, jc::OFF_MEM_PAGES as i32)]);
    emi(&mut ops, encode::addi(T0, X0, 0), T3);
    em_push(&mut ops, T0);
    h_epilogue(&mut ops);
    ops
}

/// memory.grow is fail-closed in M1 (bounded `__wasm_mem`): pops the arg,
/// pushes -1.
fn jit_h_memgrow() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_memgrow".into())];
    h_prologue(&mut ops);
    em_pop(&mut ops, T0);
    emw(&mut ops, encode::addi(T0, X0, -1));
    em_push(&mut ops, T0);
    h_epilogue(&mut ops);
    ops
}

/// select: `[v1 v2 c]` → `c ? v1 : v2`.
fn jit_h_select() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_select".into())];
    h_prologue(&mut ops);
    emw(&mut ops, encode::addi(S10, S10, -24));
    emw(&mut ops, encode::ld(T2, S10, 16));
    emw(&mut ops, encode::ld(T1, S10, 8));
    emw(&mut ops, encode::ld(T0, S10, 0));
    emw(&mut ops, encode::bne(T2, X0, 8));
    emw(&mut ops, encode::addi(T0, T1, 0));
    em_push(&mut ops, T0);
    h_epilogue(&mut ops);
    ops
}

/// DIV/REM: a1 = 0 div_s, 1 div_u, 2 rem_s, 3 rem_u; `pool` holds 4 op words.
/// Signed div traps on INT_MIN/-1 (wasm); signed rem maps it to 0 by
/// rewriting the divisor to 1.
fn jit_h_div(name: &str, pool: &str, is32: bool) -> Vec<Op> {
    let mut ops = vec![Op::Label(name.into())];
    h_prologue(&mut ops);
    // t6 = subop across emit calls (em_trap routes through jit_lia, which
    // clobbers t4/t5; the pool word is loaded into t3 at the emit point).
    ops.push(mv(T6, A1));
    em_pop2(&mut ops);
    // div0: bne t1,x0,+24; trap(DIV0)
    emw(&mut ops, encode::bne(T1, X0, 28));
    em_trap(&mut ops, i64::from(jc::TRAP_DIV0), T0);
    // signed ops (a1 even): compute flag t3 = (lhs==MIN)&(rhs==-1)
    ops.extend([Op::Andi {
        rd: T3,
        rs: T6,
        imm: 1,
    }]);
    ops.push(bne(T3, X0, &format!("{name}_emit")));
    // MIN: i32 → compare zext32(lhs) vs 1<<31; i64 → lhs vs 1<<63.
    // (generated code builds MIN as `li t2,1; slli t2,31|63` — two words.)
    if is32 {
        emw(&mut ops, encode::slli(T3, T0, 32));
        emw(&mut ops, encode::srli(T3, T3, 32));
        ops.push(li(T3, 1));
        emi(&mut ops, encode::addi(T2, X0, 0), T3);
        emw(&mut ops, encode::slli(T2, T2, 31));
        emw(&mut ops, encode::xor(T3, T3, T2));
        emw(&mut ops, encode::sltiu(T3, T3, 1));
    } else {
        ops.push(li(T3, 1));
        emi(&mut ops, encode::addi(T2, X0, 0), T3);
        emw(&mut ops, encode::slli(T2, T2, 63));
        emw(&mut ops, encode::xor(T3, T0, T2));
        emw(&mut ops, encode::sltiu(T3, T3, 1));
    }
    // rhs==-1: li t2,-1; xor t2,t1,t2; sltiu t2,t2,1; and t3,t3,t2
    ops.push(li(T3, -1));
    emi(&mut ops, encode::addi(T2, X0, 0), T3);
    emw(&mut ops, encode::xor(T2, T1, T2));
    emw(&mut ops, encode::sltiu(T2, T2, 1));
    emw(&mut ops, encode::and_(T3, T3, T2));
    // div_s (a1==0): beq t3,x0,+24; trap(OVF=10)
    // rem_s (a1==2): beq t3,x0,+8;  li t1,1  (a%1 == 0)
    ops.push(bne(T6, X0, &format!("{name}_rem")));
    emw(&mut ops, encode::beq(T3, X0, 28));
    em_trap(&mut ops, 10, T0);
    ops.push(j(&format!("{name}_emit")));
    ops.push(Op::Label(format!("{name}_rem")));
    emw(&mut ops, encode::beq(T3, X0, 8));
    emw(&mut ops, encode::addi(T1, X0, 1));
    ops.push(Op::Label(format!("{name}_emit")));
    ops.extend([
        slli(T0, T6, 2),
        la(T2, Addr::Label(pool.into())),
        add(T2, T2, T0),
        lw(T3, T2, 0),
    ]);
    ops.push(mv(A0, T3));
    ops.push(jal("jit_em"));
    em_push(&mut ops, T0);
    h_epilogue(&mut ops);
    ops
}

/// ROT: a1 = 0 rotl, 1 rotr. Emits `t2 = rot(a,n)` via two shifts.
/// `wl`/`wr` are the generated left/right shift words (t2 = t0 <op> t1);
/// `wl3`/`wr3` the same ops on (t3 = t0 <op> t3).
fn jit_h_rot(name: &str, wl: u32, wr: u32, wl3: u32, wr3: u32, mask: i64, bits: i64) -> Vec<Op> {
    let mut ops = vec![Op::Label(name.into())];
    h_prologue(&mut ops);
    ops.push(mv(T6, A1)); // subop survives emi calls
    em_pop2(&mut ops); // t0 = a, t1 = n
    ops.push(li(T3, mask));
    emi(&mut ops, encode::andi(T1, T1, 0), T3);
    ops.extend([li(T3, 0), beq(T6, T3, &format!("{name}_l"))]);
    // rotr: t2 = a >> n ; t3 = a << (bits - n)
    emw(&mut ops, wr);
    ops.push(j(&format!("{name}_rest")));
    ops.push(Op::Label(format!("{name}_l")));
    emw(&mut ops, wl);
    ops.push(Op::Label(format!("{name}_rest")));
    em_li_t3(&mut ops, bits, T3);
    emw(&mut ops, encode::sub(T3, T3, T1));
    // second shift = opposite direction on t3 — pick by subop again
    ops.extend([li(T3, 0), beq(T6, T3, &format!("{name}_l2"))]);
    emw(&mut ops, wl3); // rotr → second is left shift
    ops.push(j(&format!("{name}_or")));
    ops.push(Op::Label(format!("{name}_l2")));
    emw(&mut ops, wr3); // rotl → second is right shift
    ops.push(Op::Label(format!("{name}_or")));
    emw(&mut ops, encode::or_(T0, T2, T3));
    em_push(&mut ops, T0);
    h_epilogue(&mut ops);
    ops
}

// EXT: import trampoline. Saves the jit regs, marshals `arity` args off the
// value stack into a0.., calls the routine, restores, pushes a0.
// ---- M3: br_table / bulk mem / call_indirect / clz-ctz-popcnt / sext -------

/// BRTBL — `a1` = label count `n`; the next `n+1` records are `R_JMP` used
/// purely as an index→target table. Generated code pops the index, clamps it
/// to `n` (the default entry), reads `rec[s2+1+idx].a` (the entry's target
/// record index) and jumps to `slot0 + idx*SLOT`.
fn jit_h_brtbl() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_brtbl".into())];
    h_prologue(&mut ops);
    em_pop(&mut ops, T0); // generated t0 = index
    em64(&mut ops, T5, A1); // generated t5 = n
    emw(&mut ops, encode::bltu(T0, T5, 8));
    emw(&mut ops, encode::addi(T0, T5, 0)); // clamp idx ≥ n → n (default)
    ops.push(addi(T2, S2, 1)); // translator t2 = my rec idx + 1 (table base)
    em64(&mut ops, T3, T2); // generated t3 = table-entry record index
    emw(&mut ops, encode::add(T3, T3, T0));
    emw(&mut ops, encode::slli(T3, T3, 4));
    emw(&mut ops, encode::ld(T2, S9, OFF_RECB));
    emw(&mut ops, encode::add(T3, T3, T2));
    emw(&mut ops, encode::lw(T4, T3, 4)); // t4 = target rel record index
    ops.push(mv(A0, A4));
    ops.push(jal("jit_lia_t6")); // generated t6 = func slot0
    emw(&mut ops, encode::slli(T4, T4, SLOT_LG2));
    emw(&mut ops, encode::add(T6, T6, T4));
    emw(&mut ops, encode::jalr(X0, T6, 0));
    h_epilogue(&mut ops);
    ops
}

/// MEMFILL — pops n,val,d; fills `n` bytes at `mem+d` with `val`. Bounded: the
/// d+n OOB check caps the loop at `mem_bytes`.
fn jit_h_memfill() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_memfill".into())];
    h_prologue(&mut ops);
    // pop n→t0, val→a2, d→t2
    emw(&mut ops, encode::addi(S10, S10, -24));
    emw(&mut ops, encode::ld(T0, S10, 16));
    emw(&mut ops, encode::ld(A2, S10, 8));
    emw(&mut ops, encode::ld(T2, S10, 0));
    emw(&mut ops, encode::add(T3, T2, T0)); // bound = d+n
    emit_oob(&mut ops);
    emw(&mut ops, encode::add(T4, S8, T2)); // dst = mem + d
                                            // loop: while n!=0 { *dst = val; dst++; n-- }
    emw(&mut ops, encode::beq(T0, X0, 20));
    emw(&mut ops, encode::sb(A2, T4, 0));
    emw(&mut ops, encode::addi(T4, T4, 1));
    emw(&mut ops, encode::addi(T0, T0, -1));
    emw(&mut ops, encode::jal(X0, -16));
    h_epilogue(&mut ops);
    ops
}

/// MEMCOPY — pops n,s,d; forward byte-copy `n` bytes `mem+s → mem+d`. Both
/// bounds checked. Forward order is exact for `d ≤ s` / disjoint regions; the
/// `d ∈ (s, s+n)` overlap case copies forward too (documented limitation).
fn jit_h_memcopy() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_memcopy".into())];
    h_prologue(&mut ops);
    // pop n→t0, s→t4, d→t2 (s in t4 — emit_oob clobbers t1)
    emw(&mut ops, encode::addi(S10, S10, -24));
    emw(&mut ops, encode::ld(T0, S10, 16));
    emw(&mut ops, encode::ld(T4, S10, 8));
    emw(&mut ops, encode::ld(T2, S10, 0));
    emw(&mut ops, encode::add(T3, T2, T0)); // bound = d+n
    emit_oob(&mut ops);
    emw(&mut ops, encode::add(T3, T4, T0)); // bound = s+n
    emit_oob(&mut ops);
    emw(&mut ops, encode::add(T2, S8, T2)); // dst = mem + d
    emw(&mut ops, encode::add(T4, S8, T4)); // src = mem + s
                                            // loop: while n!=0 { *dst=*src; src++; dst++; n-- }
    emw(&mut ops, encode::beq(T0, X0, 28));
    emw(&mut ops, encode::lb(A3, T4, 0));
    emw(&mut ops, encode::sb(A3, T2, 0));
    emw(&mut ops, encode::addi(T4, T4, 1));
    emw(&mut ops, encode::addi(T2, T2, 1));
    emw(&mut ops, encode::addi(T0, T0, -1));
    emw(&mut ops, encode::jal(X0, -24));
    h_epilogue(&mut ops);
    ops
}

/// CALLI — pops the table index, then calls `jit_rt_calli(idx, typeidx)` which
/// bounds/null/sig-checks and returns the callee's code address in a0; the
/// generated code then enters it exactly like `call`. Table/sig live in the
/// `__jit_in` trailer (parsed at JitRun init into OFF_NTBL/SIGB/TBLB).
fn jit_h_calli() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_calli".into())];
    h_prologue(&mut ops);
    // pop index → generated a1
    emw(&mut ops, encode::addi(S10, S10, -8));
    emw(&mut ops, encode::ld(A1, S10, 0));
    // expected typeidx → generated a2
    emi(&mut ops, encode::addi(A2, X0, 0), A1);
    // a0 = jit_rt_calli(a1=idx, a2=typeidx)
    ops.push(la(A0, Addr::Label("jit_rt_calli".into())));
    ops.push(jal("jit_lia_t6"));
    emw(&mut ops, encode::jalr(RA, T6, 0));
    // callee addr a0 → t6; the wasm call
    emw(&mut ops, encode::addi(T6, A0, 0));
    emw(&mut ops, encode::jalr(RA, T6, 0));
    h_epilogue(&mut ops);
    ops
}

/// `jit_rt_calli` — shared call_indirect resolver (runs in generated-code
/// context; s9 = __jit hdr). a1 = table index, a2 = expected typeidx → returns
/// the callee's code address in a0, or `jit_trap`s BADFUNC/FUEL. Leaf routine.
fn jit_rt_calli_node() -> Vec<Op> {
    vec![
        Op::Label("jit_rt_calli".into()),
        // bounds: idx < ntbl
        ld(T0, S9, OFF_NTBL),
        bgeu(A1, T0, "jit_ci_bad"),
        // fidx = tbl[idx]
        ld(T0, S9, OFF_TBLB),
        slli(T1, A1, 3),
        add(T0, T0, T1),
        ld(T2, T0, 0),
        li(T3, -1),
        beq(T2, T3, "jit_ci_bad"), // null funcref
        // sig[fidx] == expected typeidx?
        ld(T0, S9, OFF_SIGB),
        slli(T1, T2, 2),
        add(T0, T0, T1),
        lw(T3, T0, 0),
        bne(T3, A2, "jit_ci_bad"),
        // fuel--
        ld(T0, S9, OFF_FUEL),
        bne(T0, X0, "jit_ci_fuok"),
        li(A0, i64::from(jc::TRAP_FUEL)),
        j("jit_trap"),
        Op::Label("jit_ci_fuok".into()),
        addi(T0, T0, -1),
        sd(T0, S9, OFF_FUEL),
        // callee = ftab[fidx]
        slli(T0, T2, 3),
        addi(T0, T0, OFF_FTAB),
        add(T0, S9, T0),
        ld(A0, T0, 0),
        ret(),
        Op::Label("jit_ci_bad".into()),
        li(A0, i64::from(jc::TRAP_BADFUNC)),
        j("jit_trap"),
    ]
}

/// CLZ — `a1`: 0 = i32, 1 = i64. Count leading zeros via a shift loop (no Zbb
/// assumed). i32 first shifts the value into the high half so a 64-bit count
/// measures 32 bits; a zero input yields the width.
fn jit_h_clz() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_clz".into())];
    h_prologue(&mut ops);
    em_pop(&mut ops, T0);
    ops.push(bne(A1, X0, "jit_clz_w64"));
    emw(&mut ops, encode::slli(T0, T0, 32)); // i32 → high half
    ops.push(Op::Label("jit_clz_w64".into()));
    emw(&mut ops, encode::addi(T2, X0, 0)); // count = 0
    emw(&mut ops, encode::beq(T0, X0, 20)); // v==0 → width
                                            // loop: while MSB clear { count++; v <<= 1 }
    emw(&mut ops, encode::blt(T0, X0, 20));
    emw(&mut ops, encode::addi(T2, T2, 1));
    emw(&mut ops, encode::slli(T0, T0, 1));
    emw(&mut ops, encode::jal(X0, -12));
    // zero case: count = 32 or 64
    ops.push(bne(A1, X0, "jit_clz_z64"));
    emw(&mut ops, encode::addi(T2, X0, 32));
    ops.push(j("jit_clz_done"));
    ops.push(Op::Label("jit_clz_z64".into()));
    emw(&mut ops, encode::addi(T2, X0, 64));
    ops.push(Op::Label("jit_clz_done".into()));
    em_push(&mut ops, T2);
    h_epilogue(&mut ops);
    ops
}

/// CTZ — `a1`: 0 = i32, 1 = i64. Count trailing zeros via a shift loop.
fn jit_h_ctz() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_ctz".into())];
    h_prologue(&mut ops);
    em_pop(&mut ops, T0);
    // i32: mask to low 32 first so the all-zero case reads 32.
    ops.push(bne(A1, X0, "jit_ctz_w64"));
    emw(&mut ops, encode::slli(T0, T0, 32));
    emw(&mut ops, encode::srli(T0, T0, 32));
    ops.push(Op::Label("jit_ctz_w64".into()));
    emw(&mut ops, encode::addi(T2, X0, 0));
    emw(&mut ops, encode::beq(T0, X0, 24)); // v==0 → width
                                            // loop: while LSB clear { count++; v >>= 1 }
    emw(&mut ops, encode::andi(T3, T0, 1));
    emw(&mut ops, encode::bne(T3, X0, 20)); // LSB set → done (push count)
    emw(&mut ops, encode::addi(T2, T2, 1));
    emw(&mut ops, encode::srli(T0, T0, 1));
    emw(&mut ops, encode::jal(X0, -16));
    ops.push(bne(A1, X0, "jit_ctz_z64"));
    emw(&mut ops, encode::addi(T2, X0, 32));
    ops.push(j("jit_ctz_done"));
    ops.push(Op::Label("jit_ctz_z64".into()));
    emw(&mut ops, encode::addi(T2, X0, 64));
    ops.push(Op::Label("jit_ctz_done".into()));
    em_push(&mut ops, T2);
    h_epilogue(&mut ops);
    ops
}

/// POPCNT — `a1`: 0 = i32, 1 = i64. Count set bits via a shift loop.
fn jit_h_popcnt() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_popcnt".into())];
    h_prologue(&mut ops);
    em_pop(&mut ops, T0);
    ops.push(bne(A1, X0, "jit_pop_w64"));
    emw(&mut ops, encode::slli(T0, T0, 32));
    emw(&mut ops, encode::srli(T0, T0, 32));
    ops.push(Op::Label("jit_pop_w64".into()));
    emw(&mut ops, encode::addi(T2, X0, 0));
    // loop: while v!=0 { count += v&1; v >>= 1 }
    emw(&mut ops, encode::beq(T0, X0, 20));
    emw(&mut ops, encode::andi(T3, T0, 1));
    emw(&mut ops, encode::add(T2, T2, T3));
    emw(&mut ops, encode::srli(T0, T0, 1));
    emw(&mut ops, encode::jal(X0, -16));
    em_push(&mut ops, T2);
    h_epilogue(&mut ops);
    ops
}

/// SEXT — `a1`: 0 i32.extend8_s, 1 i32.extend16_s, 2 i64.extend8_s,
/// 3 i64.extend16_s, 4 i64.extend32_s. Emit `slli t0,sh; srai t0,sh` with
/// sh = 56/48/32 picked by subop (byte/short/word sign-extension).
fn jit_h_sext() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_sext".into())];
    h_prologue(&mut ops);
    em_pop(&mut ops, T0);
    // subop 4 → 32; odd (1,3) → 48; even (0,2) → 56
    ops.extend([li(T0, 4), beq(A1, T0, "jit_sext_32")]);
    ops.extend([
        Op::Andi {
            rd: T0,
            rs: A1,
            imm: 1,
        },
        bne(T0, X0, "jit_sext_48"),
    ]);
    // 56
    emw(&mut ops, encode::slli(T0, T0, 56));
    emw(&mut ops, encode::srai(T0, T0, 56));
    ops.push(j("jit_sext_done"));
    ops.push(Op::Label("jit_sext_48".into()));
    emw(&mut ops, encode::slli(T0, T0, 48));
    emw(&mut ops, encode::srai(T0, T0, 48));
    ops.push(j("jit_sext_done"));
    ops.push(Op::Label("jit_sext_32".into()));
    emw(&mut ops, encode::slli(T0, T0, 32));
    emw(&mut ops, encode::srai(T0, T0, 32));
    ops.push(Op::Label("jit_sext_done".into()));
    em_push(&mut ops, T0);
    h_epilogue(&mut ops);
    ops
}

/// MEMGROW2 — bounded `memory.grow`. `memory.size` already reports the usable
/// bound (`__jit_in[mem_pages]`), which is the `__wasm_mem` ceiling — the
/// `__kget`/asyncify tail past it is ours, and `OFF_MEMB` (the OOB bound that
/// covers it) is a fixed BSS size that must never be grown into adjacent BSS.
/// `WasmAllocator.grow` reads `memory.grow(0)` for `currentPages`, so the
/// emitted handler returns the usable pages for `delta == 0` and fails closed
/// (-1) for any real `delta > 0` grow.
fn jit_h_memgrow2() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_memgrow2".into())];
    h_prologue(&mut ops);
    em_pop(&mut ops, T0); // delta → T0 (runtime)
    // cur = usable pages = __jit_in[mem_pages] (the reported memory.size).
    emw(&mut ops, encode::lw(T1, S4, jc::OFF_MEM_PAGES as i32)); // T1 = usable
    // delta==0 → return cur; delta>0 → -1 (can't grow the fixed usable bound).
    emw(&mut ops, encode::beq(T0, X0, 12)); // → word6 (ret cur)
    emw(&mut ops, encode::addi(T2, X0, -1)); // delta>0 → -1
    emw(&mut ops, encode::jal(X0, 8));       // → PUSH
    emw(&mut ops, encode::addi(T2, T1, 0));  // word6: result = cur pages
    em_push(&mut ops, T2);
    h_epilogue(&mut ops);
    ops
}

/// FPALU — `a1` = funct7 (bit0 = fmt), `a2` = f3 | mode<<4.
/// mode 0 = binary, 1 = sqrt, 2 = abs, 3 = neg. FP bit patterns ride the int
/// value stack; operands park in `f0`/`f1` through `fmv`.
fn jit_h_fpalu() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_fpalu".into())];
    h_prologue(&mut ops);
    ops.push(mv(T2, A1)); // funct7 (fmt in bit0)
    ops.push(Op::Andi {
        rd: T3,
        rs: A1,
        imm: 1,
    }); // fmt
    ops.push(srli(T6, A2, 4)); // mode
    ops.push(Op::Andi {
        rd: A4,
        rs: A2,
        imm: 0xf,
    }); // funct3
    ops.push(li(A0, 2));
    ops.push(beq(T6, A0, "jit_fp_abs"));
    ops.push(li(A0, 3));
    ops.push(beq(T6, A0, "jit_fp_neg"));
    ops.push(li(A0, 1));
    ops.push(beq(T6, A0, "jit_fp_unary"));
    // binary: pop2 → fmv i2f → fop f0,f0,f1 → fmv f2i → push
    em_pop2(&mut ops);
    em_fmv_i2f(&mut ops, T3, T0, F0);
    em_fmv_i2f(&mut ops, T3, T1, F1);
    em_fop(&mut ops, T2, F1, F0, A4, F0);
    em_fmv_f2i(&mut ops, T3, F0, T0);
    em_push(&mut ops, T0);
    ops.push(j("jit_fp_done"));
    // sqrt (unary)
    ops.push(Op::Label("jit_fp_unary".into()));
    em_pop(&mut ops, T0);
    em_fmv_i2f(&mut ops, T3, T0, F0);
    em_fop(&mut ops, T2, 0, F0, A4, F0);
    em_fmv_f2i(&mut ops, T3, F0, T0);
    em_push(&mut ops, T0);
    ops.push(j("jit_fp_done"));
    // abs — clear the sign bit via slli/srli by 33 (f32) or 1 (f64):
    // shamt = 33 - (fmt << 5). The shamt rides in A5 — `emi`'s imm_reg must not
    // be A0/A1/T0/T1 (jit_em/jit_emi clobber them).
    ops.push(Op::Label("jit_fp_abs".into()));
    em_pop(&mut ops, T0);
    ops.push(slli(A5, T3, 5));
    ops.push(li(A0, 33));
    ops.push(sub(A5, A0, A5));
    emi(&mut ops, encode::slli(T0, T0, 0), A5);
    emi(&mut ops, encode::srli(T0, T0, 0), A5);
    em_push(&mut ops, T0);
    ops.push(j("jit_fp_done"));
    // neg — flip the sign bit: t1 = -1 << (31 f32 | 63 f64) then xor.
    ops.push(Op::Label("jit_fp_neg".into()));
    em_pop(&mut ops, T0);
    emw(&mut ops, encode::addi(T1, X0, -1));
    ops.push(slli(A5, T3, 5));
    ops.push(addi(A5, A5, 31));
    emi(&mut ops, encode::slli(T1, T1, 0), A5);
    emw(&mut ops, encode::xor(T0, T0, T1));
    em_push(&mut ops, T0);
    ops.push(Op::Label("jit_fp_done".into()));
    h_epilogue(&mut ops);
    ops
}

/// FPCMP — `a1` = funct7 (0x50|fmt), `a2` = f3 | swap<<4 | invert<<5.
/// Pops two FP bit patterns, emits the flt/fle/feq with the operand order the
/// `swap` bit dictates, optionally xoris for `ne`, pushes the i32 0/1.
fn jit_h_fpcmp() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_fpcmp".into())];
    h_prologue(&mut ops);
    ops.push(mv(T2, A1)); // funct7 (0x50|fmt)
    ops.push(Op::Andi {
        rd: T3,
        rs: A1,
        imm: 1,
    }); // fmt
    ops.push(Op::Andi {
        rd: A4,
        rs: A2,
        imm: 0xf,
    }); // funct3
    ops.push(srli(T6, A2, 4)); // swap|invert<<1
    em_pop2(&mut ops); // t0 = lhs, t1 = rhs
    em_fmv_i2f(&mut ops, T3, T0, F0);
    em_fmv_i2f(&mut ops, T3, T1, F1);
    ops.push(Op::Andi {
        rd: A0,
        rs: T6,
        imm: 1,
    }); // swap?
    ops.push(bne(A0, X0, "jit_fpcmp_sw"));
    em_fop(&mut ops, T2, F1, F0, A4, T0); // fcmp f0,f1 → int t0
    ops.push(j("jit_fpcmp_inv"));
    ops.push(Op::Label("jit_fpcmp_sw".into()));
    em_fop(&mut ops, T2, F0, F1, A4, T0); // swapped (gt/ge)
    ops.push(Op::Label("jit_fpcmp_inv".into()));
    ops.push(Op::Andi {
        rd: A0,
        rs: T6,
        imm: 2,
    }); // invert?
    ops.push(beq(A0, X0, "jit_fpcmp_push"));
    emw(&mut ops, encode::addi(T3, X0, 1));
    emw(&mut ops, encode::xor(T0, T0, T3)); // t0 ^= 1
    ops.push(Op::Label("jit_fpcmp_push".into()));
    em_push(&mut ops, T0);
    h_epilogue(&mut ops);
    ops
}

/// FPCVT — `a1` = funct7 | (rs2sel<<8). Direction is read off funct7:
/// 0x60/0x61 fp→int, 0x68/0x69 int→fp, 0x20/0x21 fp→fp (demote/promote).
/// The int width/signedness lives in rs2sel. FP src/dst widths come from the
/// funct7 low bit (or 0x20 demote / 0x21 promote).
fn jit_h_fpcvt() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_fpcvt".into())];
    h_prologue(&mut ops);
    ops.push(mv(T2, A1)); // funct7|rs2sel<<8
    ops.push(Op::Andi {
        rd: T3,
        rs: A1,
        imm: 0xff,
    }); // funct7
    ops.push(srli(T6, A1, 8)); // rs2sel
                               // class: f7&0x7c == 0x60 → fp→int; 0x68 → int→fp; 0x20/0x21 → fp→fp
    ops.push(Op::Andi {
        rd: A0,
        rs: T3,
        imm: 0x7c,
    });
    ops.push(li(A1, 0x60));
    ops.push(beq(A0, A1, "jit_fpcvt_f2i"));
    ops.push(li(A1, 0x68));
    ops.push(beq(A0, A1, "jit_fpcvt_i2f"));
    // --- fp→fp (demote 0x20: f64→f32 ; promote 0x21: f32→f64) ---
    // demote reads f64 (in_fmt 1), promote reads f32 (in_fmt 0). Since demote
    // f7=0x20 (bit0=0) and promote f7=0x21 (bit0=1), in_fmt = !(f7&1).
    em_pop(&mut ops, T0);
    ops.push(li(A0, 1));
    ops.push(Op::Andi {
        rd: A1,
        rs: T3,
        imm: 1,
    });
    ops.push(sub(A5, A0, A1)); // in_fmt = 1 - (f7&1)
    em_fmv_i2f(&mut ops, A5, T0, F0);
    // fcvt.f_to_f f0 <- f0 : fpr(funct7, rs2=rs2sel, rs1=f0, f3=0, rd=f0)
    em_fop_r2(&mut ops, T3, T6, F0, 0, F0);
    // fcvt.s.d (0x20) out f32 → out_fmt 0 ; fcvt.d.s (0x21) out f64 → out_fmt 1.
    ops.push(Op::Andi {
        rd: A5,
        rs: T3,
        imm: 1,
    });
    em_fmv_f2i(&mut ops, A5, F0, T0);
    em_push(&mut ops, T0);
    ops.push(j("jit_fpcvt_done"));
    // --- int→fp (convert): pop int → fcvt int→f0 → fmv f2i → push ---
    ops.push(Op::Label("jit_fpcvt_i2f".into()));
    em_pop(&mut ops, T0);
    // fcvt.{s|d}.{w|wu|l|lu} f0 <- t0 : fpr(funct7, rs2sel, rs1=t0, f3=0, rd=f0)
    em_fop_r2(&mut ops, T3, T6, T0, 0, F0);
    ops.push(Op::Andi {
        rd: A5,
        rs: T3,
        imm: 1,
    }); // dst fmt = f7&1
    em_fmv_f2i(&mut ops, A5, F0, T0);
    em_push(&mut ops, T0);
    ops.push(j("jit_fpcvt_done"));
    // --- fp→int (trunc): pop fp bits → fmv i2f → fcvt f0→t0 → push ---
    ops.push(Op::Label("jit_fpcvt_f2i".into()));
    em_pop(&mut ops, T0);
    ops.push(Op::Andi {
        rd: A5,
        rs: T3,
        imm: 1,
    }); // src fmt = f7&1
    em_fmv_i2f(&mut ops, A5, T0, F0);
    // fcvt.{w|wu|l|lu}.{s|d} t0 <- f0 : fpr(funct7, rs2sel, rs1=f0, rm=1 RTZ,
    // rd=t0) — WASM trunc rounds toward zero.
    em_fop_r2(&mut ops, T3, T6, F0, 1, T0);
    em_push(&mut ops, T0);
    ops.push(Op::Label("jit_fpcvt_done".into()));
    h_epilogue(&mut ops);
    ops
}

fn jit_h_ext() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_ext".into())];
    h_prologue(&mut ops);
    // t4 = routine addr = jit_ext_tab[a1-1]
    ops.extend([
        addi(T0, A1, -1),
        slli(T0, T0, 3),
        la(T2, Addr::Label("jit_ext_tab".into())),
        add(T2, T2, T0),
        ld(T4, T2, 0),
    ]);
    // t5 = arity = rec.b & 0xff ; has_result = (rec.b >> 8) & 1 parked at
    // SP+0 (survives the emit helpers that clobber t6).
    ops.extend([
        Op::Andi {
            rd: T5,
            rs: A2,
            imm: 0xff,
        },
        srli(T6, A2, 8),
        Op::Andi {
            rd: T6,
            rs: T6,
            imm: 1,
        },
        sd(T6, SP, 0),
    ]);
    // emit marshal loop: a_i = ld -8*(arity-i)(s10), i in 0..arity
    ops.extend([
        mv(T3, X0),
        Op::Label("jit_ext_marshal".into()),
        bgeu(T3, T5, "jit_ext_done"),
        // off = -8*(arity - i)
        sub(T0, T5, T3),
        slli(T0, T0, 3),
        sub(T0, X0, T0),
        mv(A1, T0),
        // template = ld a_i, s10, 0 = (S10<<15)|(3<<12)|((10+i)<<7)|0x03
        li(T1, i64::from((S10 << 15) | (0x3 << 12) | 0x03)),
        addi(T2, T3, i64::from(A0) as i32), // dest reg number = A0 + i
        slli(T2, T2, 7),
        or_(A0, T1, T2),
        jal("jit_emi"),
        addi(T3, T3, 1),
        j("jit_ext_marshal"),
        Op::Label("jit_ext_done".into()),
    ]);
    // s10 -= arity*8  (emit: li t3, arity*8; sub s10,s10,t3)
    ops.push(slli(T3, T5, 3));
    emi(&mut ops, encode::addi(T3, X0, 0), T3);
    emw(&mut ops, encode::sub(S10, S10, T3));
    // save s8/s10/s11; call; restore
    emw(&mut ops, encode::sd(S8, S9, OFF_SAVE));
    emw(&mut ops, encode::sd(S10, S9, OFF_SAVE + 16));
    emw(&mut ops, encode::sd(S11, S9, OFF_SAVE + 24));
    ops.push(mv(A0, T4));
    ops.push(jal("jit_lia_t6"));
    emw(&mut ops, encode::jalr(RA, T6, 0));
    emw(&mut ops, encode::ld(S8, S9, OFF_SAVE));
    emw(&mut ops, encode::ld(S10, S9, OFF_SAVE + 16));
    emw(&mut ops, encode::ld(S11, S9, OFF_SAVE + 24));
    // push a0 only when the import returns a value — a void import leaves
    // no dead slot on the guest value stack.
    ops.extend([ld(T6, SP, 0), beq(T6, X0, "jit_ext_nores")]);
    em_push(&mut ops, A0);
    ops.push(Op::Label("jit_ext_nores".into()));
    h_epilogue(&mut ops);
    ops
}

/// TRAP record → emit `li a0,code; li a1,b; li t6,jit_trap; jalr`.
fn jit_h_trap() -> Vec<Op> {
    let mut ops = vec![Op::Label("jit_h_trap".into())];
    h_prologue(&mut ops);
    ops.push(mv(T3, A1));
    emi(&mut ops, encode::addi(A0, X0, 0), T3);
    ops.push(mv(A0, A2));
    ops.push(mv(A1, A0));
    ops.extend([li(A0, i64::from(A1)), jal("jit_lia")]); // li a1, rec.b(32b)
    ops.push(la(A0, Addr::Label("jit_trap".into())));
    ops.push(jal("jit_lia_t6"));
    emw(&mut ops, encode::jalr(X0, T6, 0));
    h_epilogue(&mut ops);
    ops
}

// ===========================================================================
// jit_trap — generated code lands here on a bounded fault. a0=code, a1=aux.
// ===========================================================================

/// jit_memcpy: a0=dst, a1=src, a2=len — word loop then byte tail. Bounded by
/// the image's data/global sizes; used for `__wasm_mem` and globals init.
fn jit_memcpy_node() -> Vec<Op> {
    vec![
        Op::Label("jit_memcpy".into()),
        li(T0, 8),
        Op::Label("jit_mcp_w".into()),
        bltu(A2, T0, "jit_mcp_tail"),
        ld(T1, A1, 0),
        sd(T1, A0, 0),
        addi(A0, A0, 8),
        addi(A1, A1, 8),
        addi(A2, A2, -8),
        j("jit_mcp_w"),
        Op::Label("jit_mcp_tail".into()),
        beq(A2, X0, "jit_mcp_done"),
        Op::Label("jit_mcp_b".into()),
        lbu(T1, A1, 0),
        sb(T1, A0, 0),
        addi(A0, A0, 1),
        addi(A1, A1, 1),
        addi(A2, A2, -1),
        bne(A2, X0, "jit_mcp_b"),
        Op::Label("jit_mcp_done".into()),
        ret(),
    ]
}

fn jit_trap_node() -> Vec<Op> {
    let mut ops = vec![
        Op::Comment(
            "jit_trap — generated-code fault: a0=code, a1=aux (orig opcode). Prints \
             WASM-JIT-TRAP <code> <aux> and rejoins JitRun's epilogue."
                .into(),
        ),
        Op::Label("jit_trap".into()),
        mv(T3, A0),
        mv(T5, A1),
        sd(T3, S9, OFF_ERR),
        li(T0, STATE_TRAP),
        sd(T0, S9, OFF_STATE),
    ];
    puts(&mut ops, "WASM-JIT-TRAP ");
    ops.push(mv(T0, T3));
    put_hex(&mut ops, "jit_trap_hex");
    putc(&mut ops, b' ' as i64);
    ops.push(mv(T0, T5));
    put_hex(&mut ops, "jit_trap_hex2");
    putc(&mut ops, b'\n' as i64);
    ops.extend([
        // Continuation slot: JitRun parks `jit_after`, JitCall parks
        // `jit_call_done`. `sp` is restored first — a trap N generated calls
        // deep would otherwise unwind into a frame N*16 bytes off the caller's
        // saved-register block. Large offsets → li+add.
        li(T6, i64::from(OFF_RESUME)),
        add(T6, S9, T6),
        ld(T6, T6, 0),
        li(T5, i64::from(OFF_SPSAVE)),
        add(T5, S9, T5),
        ld(SP, T5, 0),
        Op::Jalr {
            rd: X0,
            rs: T6,
            imm: 0,
        },
    ]);
    ops
}

// ===========================================================================
// JitRun — init → translate → fence.i → run entry → report
// ===========================================================================

fn jit_run_node() -> Vec<Op> {
    let mut ops = vec![
        Op::Comment(
            "JitRun — guest wasm JIT: translate __jit_in → __jit_code, fence.i, \
             run _start, print WASM-JIT markers. Masks SIE while it owns s8-s11."
                .into(),
        ),
        Op::Glob("JitRun".into()),
        Op::Label("JitRun".into()),
        // frame: ra + s0..s11 + one spare slot for the saved sie
        addi(SP, SP, -120),
        sd(RA, SP, 104),
        sd(S0, SP, 96),
        sd(S1, SP, 88),
        sd(S2, SP, 80),
        sd(S3, SP, 72),
        sd(S4, SP, 64),
        sd(S5, SP, 56),
        sd(S6, SP, 48),
        sd(S7, SP, 40),
        sd(S8, SP, 32),
        sd(S9, SP, 24),
        sd(S10, SP, 16),
        sd(S11, SP, 8),
        sd(TP, SP, 0),
        // mask SEIE+STIE while jit s-regs are live — a tick inside
        // translate/execute would clobber s0-s5 via DomPaint. Park the old sie
        // in the spare slot (SP+112): SP+96 already holds the caller's s0, and
        // s0 itself is JIT loop state, so neither can carry sie across.
        Op::Csrrc {
            rd: S0,
            csr: encode::CSR_SIE,
            rs: X0,
        },
        sd(S0, SP, 112),
        li(T0, encode::SIE_SEIE | encode::SIE_STIE),
        Op::Csrrc {
            rd: X0,
            csr: encode::CSR_SIE,
            rs: T0,
        },
        la(S9, Addr::JitHdr),
        la(S8, Addr::WasmMem),
        la(S5, Addr::JitCode),
        la(S4, Addr::JitIn),
        // image magic
        lw(T0, S4, 0),
        li(T1, i64::from(jc::MAGIC)),
        bne(T0, T1, "jit_noimg"),
        // hdr init
        li(T0, JIT_MAGIC as i64),
        sd(T0, S9, OFF_MAGIC),
        li(T0, STATE_XLATE),
        sd(T0, S9, OFF_STATE),
        li(T0, FUEL),
        sd(T0, S9, OFF_FUEL),
        sd(X0, S9, OFF_CODELEN),
        sd(X0, S9, OFF_ERR),
        sd(X0, S9, OFF_RESULT),
        li(T0, i64::from(OFF_AXB)),
        add(T0, S9, T0),
        sd(X0, T0, 0),
        // Trap continuation, parked before translation so a *translate-time*
        // trap (jit_badop/ovf/ext/badfunc) unwinds to `jit_after` just like an
        // execution-time one — OFF_RESUME/OFF_SPSAVE must never be garbage when
        // jit_trap reads them. Large offsets → li+add.
        li(T0, i64::from(OFF_SPSAVE)),
        add(T0, S9, T0),
        sd(SP, T0, 0),
        la(T0, Addr::Label("jit_after".into())),
        li(T1, i64::from(OFF_RESUME)),
        add(T1, S9, T1),
        sd(T0, T1, 0),
        // code_end = s5 + nrecs*SLOT + nfuncs*64 + 4096, capped — mirrors
        // code_arena_bytes so the emit cursor cannot leave the arena.
        lw(T0, S4, jc::OFF_NRECORDS as i32),
        li(T1, SLOT_BYTES as i64),
        Op::Mul {
            rd: T0,
            rs1: T0,
            rs2: T1,
        },
        lw(T1, S4, jc::OFF_NFUNCS as i32),
        slli(T1, T1, 7), // nfuncs*128 — prologue + bounded local-zero loop
        add(T0, T0, T1),
        li(T1, 4096),
        add(T0, T0, T1),
        li(T1, jc::MAX_JIT_CODE_BYTES as i64),
        bltu(T0, T1, "jit_ce_ok"),
        mv(T0, T1),
        Op::Label("jit_ce_ok".into()),
        add(T0, S5, T0),
        sd(T0, S9, OFF_CODE_END),
        // mem_bytes = pages << 16; `+KGET_TAIL_BYTES` extends the OOB bound
        // over the asyncify scratch + `libwasm_await_value` string pool past
        // `mem_pages`. `memory.size` reports `mem_pages` (read from `__jit_in`
        // at jit_h_memsize), so the cell's heap bound never reaches the tail.
        lw(T0, S4, jc::OFF_MEM_PAGES as i32),
        slli(T0, T0, 16),
        li(T1, crate::kget::KGET_TAIL_BYTES as i64),
        add(T0, T0, T1),
        sd(T0, S9, OFF_MEMB),
        // rec_base = s4 + 32 + nfuncs*24
        lw(T0, S4, jc::OFF_NFUNCS as i32),
        li(T1, 24),
        Op::Mul {
            rd: T0,
            rs1: T0,
            rs2: T1,
        },
        addi(T0, T0, 32),
        add(T0, S4, T0),
        sd(T0, S9, OFF_RECB),
        // data_off = rec_base + nrecords*16 + glob_len*8 ; copy → s8
        lw(T0, S4, jc::OFF_NRECORDS as i32),
        slli(T0, T0, 4),
        ld(T1, S9, OFF_RECB),
        add(T0, T1, T0), // glob area start
        lw(T1, S4, jc::OFF_GLOB_LEN as i32),
        slli(T1, T1, 3),
        add(A1, T0, T1), // data addr in jit_in
        lw(A2, S4, jc::OFF_DATA_LEN as i32),
        mv(A0, S8),
        jal("jit_memcpy"),
        // globals → s9 + OFF_GLOB
        lw(T0, S4, jc::OFF_NRECORDS as i32),
        slli(T0, T0, 4),
        ld(T1, S9, OFF_RECB),
        add(A1, T1, T0),
        lw(A2, S4, jc::OFF_GLOB_LEN as i32),
        slli(A2, A2, 3),
        li(T0, OFF_GLOB as i64),
        add(A0, S9, T0),
        jal("jit_memcpy"),
        // wasm linear memory is zero-init: clear [data_len, mem_bytes).
        lw(T0, S4, jc::OFF_DATA_LEN as i32),
        ld(T1, S9, OFF_MEMB),
        bgeu(T0, T1, "jit_zmem_done"),
        add(T0, S8, T0),
        add(T1, S8, T1),
        Op::Label("jit_zmem".into()),
        sd(X0, T0, 0),
        addi(T0, T0, 8),
        bltu(T0, T1, "jit_zmem"),
        Op::Label("jit_zmem_done".into()),
        // M3 trailer: parse the call_indirect sig/funcref tables that follow
        // the data image. meta = data_addr + align8(data_len); data_addr =
        // rec_base + nrec*16 + glob_len*8 (all absolute, __jit_in rodata).
        lw(T0, S4, jc::OFF_NRECORDS as i32),
        slli(T0, T0, 4),
        ld(T1, S9, OFF_RECB),
        add(T0, T1, T0),
        lw(T1, S4, jc::OFF_GLOB_LEN as i32),
        slli(T1, T1, 3),
        add(T0, T0, T1), // T0 = data addr (abs)
        lw(T1, S4, jc::OFF_DATA_LEN as i32),
        addi(T1, T1, 7),
        Op::Andi {
            rd: T1,
            rs: T1,
            imm: -8,
        },
        add(T0, T0, T1), // T0 = meta addr (abs)
        lw(T1, T0, jc::META_MAGIC as i32),
        li(T2, i64::from(jc::TMETA_MAGIC)),
        bne(T1, T2, "jit_meta_done"), // M1 image: ntbl/sigb/tblb stay 0
        lw(T1, T0, jc::META_NTBL as i32),
        sd(T1, S9, OFF_NTBL),
        addi(T1, T0, jc::META_SIG as i32),
        sd(T1, S9, OFF_SIGB),
        // tbl base = meta + 8 + align8(nfuncs*4)
        lw(T2, S4, jc::OFF_NFUNCS as i32),
        slli(T2, T2, 2),
        addi(T2, T2, 7),
        Op::Andi {
            rd: T2,
            rs: T2,
            imm: -8,
        },
        addi(T3, T0, jc::META_SIG as i32),
        add(T3, T3, T2),
        sd(T3, S9, OFF_TBLB),
        // AX trailer = tblb + n_table*8 — the asyncify/listener funcidx table
        // JitAx/JitCall read to re-enter cell functions. T3 still holds tblb;
        // OFF_AXB is a large offset → li+add into T1 for the store base.
        ld(T0, S9, OFF_NTBL),
        slli(T0, T0, 3),
        add(T0, T3, T0),
        li(T1, i64::from(OFF_AXB)),
        add(T1, S9, T1),
        sd(T0, T1, 0),
        Op::Label("jit_meta_done".into()),
        // value stack / cursor
        la(S10, Addr::JitStk),
        mv(S11, S10),
        mv(S6, S5),
        // func loop
        mv(S0, X0),
        lw(S1, S4, jc::OFF_NFUNCS as i32),
        Op::Label("jit_floop".into()),
        bgeu(S0, S1, "jit_fdone"),
        // fhdr = s4 + 32 + f*24
        li(T1, 24),
        Op::Mul {
            rd: T0,
            rs1: S0,
            rs2: T1,
        },
        addi(T2, T0, 32),
        add(T2, S4, T2),
        lw(T3, T2, 20),
        Op::Andi {
            rd: T3,
            rs: T3,
            imm: 1,
        },
        bne(T3, X0, "jit_fimp"),
        // ftab[f] = s6 (entry = prologue addr)
        slli(T0, S0, 3),
        addi(T0, T0, OFF_FTAB),
        add(T0, S9, T0),
        sd(S6, T0, 0),
        // prologue: addi sp,-16; sd ra,8(sp); sd s11,0(sp)
        li(A0, i64::from(encode::addi(SP, SP, -16))),
        jal("jit_em"),
        li(A0, i64::from(encode::sd(RA, SP, 8))),
        jal("jit_em"),
        li(A0, i64::from(encode::sd(S11, SP, 0))),
        jal("jit_em"),
        // s11 = s10 - np*8   — np*8 can exceed a 12-bit imm, so the offset is
        // emitted as a full jit_lia `li` (4 words), not a truncated jit_emi.
        lw(T3, T2, 8),  // nparams
        lw(T4, T2, 12), // nlocals
        lw(T0, T2, 16), // nresults
        sd(T0, S9, OFF_NRES),
        lw(T0, T2, 0), // bc_off
        sd(T0, S9, OFF_BCOFF),
        mv(S2, T0),
        lw(T0, T2, 4), // bc_len
        add(S3, S2, T0),
        slli(A1, T3, 3), // value = np*8
        li(A0, i64::from(T0)),
        jal("jit_lia"), // emit li t0, np*8
        li(A0, i64::from(encode::sub(S11, S10, T0))),
        jal("jit_em"),
        // zero extra locals np..nl via a bounded generated loop — a constant
        // ~6 words, so a 845-local frame can't overflow the code arena the way
        // one `sd` per local did. NOTE jit_lia clobbers t4/t5, so np/nl are
        // re-loaded from the func header (t2, which jit_lia preserves).
        //   emit: li t5,np*8 ; li t6,nl*8 ; zl: add t4,s11,t5 ; sd x0,0(t4) ;
        //         addi t5,t5,8 ; bltu t5,t6,-12
        lw(T3, T2, 8),             // np (reload)
        lw(T4, T2, 12),            // nl (reload)
        bgeu(T3, T4, "jit_zdone"), // np >= nl → no extra locals to zero
        slli(A1, T3, 3),
        li(A0, i64::from(T5)),
        jal("jit_lia"), // emit li t5, np*8
        lw(T4, T2, 12), // nl (reload — jit_lia clobbered t4)
        slli(A1, T4, 3),
        li(A0, i64::from(T6)),
        jal("jit_lia"), // emit li t6, nl*8
        li(A0, i64::from(encode::add(T4, S11, T5))),
        jal("jit_em"), // zl: add t4,s11,t5
        li(A0, i64::from(encode::sd(X0, T4, 0))),
        jal("jit_em"), // sd x0,0(t4)
        li(A0, i64::from(encode::addi(T5, T5, 8))),
        jal("jit_em"), // addi t5,t5,8
        li(A0, i64::from(encode::bltu(T5, T6, -12))),
        jal("jit_em"), // bltu t5,t6, zl (-12B)
        Op::Label("jit_zdone".into()),
        // s10 = s11 + nl*8 — full-width li (nl*8 can exceed 12 bits).
        lw(T4, T2, 12), // nl (reload — jit_lia clobbered t4)
        slli(A1, T4, 3),
        li(A0, i64::from(T0)),
        jal("jit_lia"), // emit li t0, nl*8
        li(A0, i64::from(encode::add(S10, S11, T0))),
        jal("jit_em"),
        // s7 = slot0 base (after prologue)
        mv(S7, S6),
        // record loop
        Op::Label("jit_rloop".into()),
        bgeu(S2, S3, "jit_fnext"),
        // slot_base = s7 + (s2 - bc_off)*SLOT
        ld(T0, S9, OFF_BCOFF),
        sub(T0, S2, T0),
        slli(T0, T0, SLOT_LG2),
        add(A3, S7, T0),
        // rec_addr = rec_base + s2*16
        ld(T1, S9, OFF_RECB),
        slli(T2, S2, 4),
        add(A6, T1, T2),
        lw(A0, A6, 0), // op
        lw(A1, A6, 4), // a
        ld(A2, A6, 8), // b
        mv(A4, S7),
        mv(A5, S4),
        ld(A7, S9, OFF_NRES),
        // dispatch through jit_disp (Dw64 table)
        li(T0, R_OP_COUNT),
        bgeu(A0, T0, "jit_badop"),
        slli(T0, A0, 3),
        la(T1, Addr::Label("jit_disp".into())),
        add(T1, T1, T0),
        ld(T6, T1, 0),
        Op::Jalr {
            rd: RA,
            rs: T6,
            imm: 0,
        },
        // pad to slot end with NOPs; a handler that overran its slot traps.
        // slot_end lives in a3+slot — computed each iter because jit_em
        // clobbers t0 (it loads code_end there).
        Op::Label("jit_pad".into()),
        li(T1, SLOT_BYTES as i64),
        add(T1, A3, T1),
        // s6 > slot_end → a handler overran its 128B slot and every later
        // slot-relative jump target in this function is misaligned. Trap with
        // aux = record index so the offending record op is identifiable.
        bltu(T1, S6, "jit_ovf"),
        bgeu(S6, T1, "jit_padded"),
        li(A0, i64::from(encode::addi(X0, X0, 0))),
        jal("jit_em"),
        j("jit_pad"),
        Op::Label("jit_ovf".into()),
        li(A0, b'O' as i64),
        li(A7, SBI_PUTCHAR),
        Op::Ecall,
        li(A0, i64::from(jc::TRAP_XLATE)),
        mv(A1, S2), // aux = record index whose handler overran its slot
        j("jit_trap"),
        Op::Label("jit_badop".into()),
        li(A0, b'B' as i64),
        li(A7, SBI_PUTCHAR),
        Op::Ecall,
        li(A0, i64::from(jc::TRAP_XLATE)),
        ld(A1, A6, 0), // aux = the bad record op
        j("jit_trap"),
        Op::Label("jit_padded".into()),
        addi(S2, S2, 1),
        j("jit_rloop"),
        // imported func: ftab[f] = jit_trap_badfunc
        Op::Label("jit_fimp".into()),
        la(T0, Addr::Label("jit_trap_badfunc".into())),
        slli(T1, S0, 3),
        addi(T1, T1, OFF_FTAB),
        add(T1, S9, T1),
        sd(T0, T1, 0),
        Op::Label("jit_fnext".into()),
        addi(S0, S0, 1),
        j("jit_floop"),
        Op::Label("jit_fdone".into()),
        // code_len; fence.i; state=ok
        sub(T0, S6, S5),
        sd(T0, S9, OFF_CODELEN),
        Op::FenceI,
        li(T0, STATE_OK),
        sd(T0, S9, OFF_STATE),
    ];
    puts(&mut ops, "WASM-JIT-F ");
    ops.push(lw(T0, S4, jc::OFF_NFUNCS as i32));
    put_hex(&mut ops, "jit_f_hex");
    puts(&mut ops, " C ");
    ops.push(ld(T0, S9, OFF_CODELEN));
    put_hex(&mut ops, "jit_c_hex");
    putc(&mut ops, b'\n' as i64);
    ops.extend([
        // entry call: t6 = ftab[entry]  (OFF_RESUME/OFF_SPSAVE already park
        // `jit_after` + this frame — set at hdr-init so translate-time traps
        // unwind identically to execution-time ones)
        lw(T0, S4, jc::OFF_ENTRY as i32),
        slli(T0, T0, 3),
        addi(T0, T0, OFF_FTAB),
        add(T0, S9, T0),
        ld(T6, T0, 0),
        // `_start(i32 heap_base)` reads param0 off the value stack
        // (locals[0] = 0(S11), S11 = S10 - np*8). Push `__heap_base`
        // (glob[1]) onto S10 so the cell's WasmAllocator inits `begin`/`current`
        // to the real heap — not the garbage slot that overflowed into the
        // `__kget`/asyncify tail and clobbered the awaited body.
        li(T0, i64::from(OFF_GLOB) + 8),
        add(T0, S9, T0),
        ld(T0, T0, 0),   // __heap_base global value
        sd(T0, S10, 0),  // push arg0
        addi(S10, S10, 8),
        Op::Jalr {
            rd: RA,
            rs: T6,
            imm: 0,
        },
        Op::Label("jit_after".into()),
        // state==ok → the entry call returned cleanly; state==trap → jit_done.
        ld(T0, S9, OFF_STATE),
        li(T1, STATE_OK),
        bne(T0, T1, "jit_done"),
        // ---- Asyncify drive: an awaited `_start` unwound out here. --------
        // `LwAwaitVoid` armed `__asyncify_state=UNWINDING`; the cell's own
        // instrumentation saved its operand stack to `__asyncify_data` and
        // returned. The promise already resolved synchronously (`cur`), so
        // settle it: stop_unwind → start_rewind(data) → re-invoke `_start`,
        // which rewinds to the await point and continues to
        // `libwasm_await_value`. Loop — each iteration settles one await.
        li(A0, i64::from(jc::AX_STATE_GLOB)),
        jal("JitAx"),
        Op::Blt {
            rs1: A0,
            rs2: X0,
            to: "jit_result".into(),
        }, // no asyncify globals → done
        slli(T0, A0, 3),
        li(T1, OFF_GLOB as i64),
        add(T0, T0, T1),
        add(T0, S9, T0),
        ld(T0, T0, 0), // __asyncify_state
        li(T1, 1),     // STATE_UNWINDING
        bne(T0, T1, "jit_result"),
    ]);
    // DIAG: UNWINDING → print __asyncify_data {pos,end} to see how far the
    // operand-stack dump reached (pos - data-8 = stack bytes; overflow past
    // data+ASTK = pool clobber).
    puts(&mut ops, " UWpos=");
    ops.extend([
        ld(T0, S9, OFF_MEMB),
        li(T1, crate::kget::KGET_TAIL_BYTES as i64),
        sub(T0, T0, T1),           // data offset
        la(T2, Addr::WasmMem),
        add(T2, T2, T0),           // &__asyncify_data
        lw(T0, T2, 0),             // pos
    ]);
    put_hex(&mut ops, "jit_uwp_hex");
    puts(&mut ops, " end=");
    ops.extend([
        // put_hex clobbered T2 — recompute &__asyncify_data.
        ld(T0, S9, OFF_MEMB),
        li(T1, crate::kget::KGET_TAIL_BYTES as i64),
        sub(T0, T0, T1),
        la(T2, Addr::WasmMem),
        add(T2, T2, T0),
        lw(T0, T2, 4), // end
    ]);
    put_hex(&mut ops, "jit_uwe_hex");
    putc(&mut ops, b'\n' as i64);
    ops.extend([
        // UNWINDING → JitCall(asyncify_stop_unwind)
        li(A0, i64::from(jc::AX_STOP_UNWIND)),
        jal("JitAx"),
        mv(A1, X0), // nargs=0
        jal("JitCall"),
        // UNWINDING → JitCall(asyncify_start_rewind, data)
        li(A0, i64::from(jc::AX_START_REWIND)),
        jal("JitAx"),
        li(A1, 1), // nargs=1
        // a2 = data = OFF_MEMB - KGET_TAIL_BYTES (the scratch base, = what
        // `LwAwaitVoid` stored in `__asyncify_data`)
        ld(T0, S9, OFF_MEMB),
        li(T1, crate::kget::KGET_TAIL_BYTES as i64),
        sub(A2, T0, T1),
        jal("JitCall"),
        // re-park the trap continuation JitCall clobbered → jit_after/this SP
        li(T0, i64::from(OFF_SPSAVE)),
        add(T0, S9, T0),
        sd(SP, T0, 0),
        la(T0, Addr::Label("jit_after".into())),
        li(T1, i64::from(OFF_RESUME)),
        add(T1, S9, T1),
        sd(T0, T1, 0),
        // re-invoke the entry (asyncify rewinds into the await continuation)
        lw(T0, S4, jc::OFF_ENTRY as i32),
        slli(T0, T0, 3),
        addi(T0, T0, OFF_FTAB),
        add(T0, S9, T0),
        ld(T6, T0, 0),
        Op::Jalr {
            rd: RA,
            rs: T6,
            imm: 0,
        },
        j("jit_after"),
        Op::Label("jit_result".into()),
        ld(T0, S10, -8),
        sd(T0, S9, OFF_RESULT),
    ]);
    puts(&mut ops, "WASM-JIT ");
    ops.push(ld(T0, S9, OFF_RESULT));
    put_hex(&mut ops, "jit_r_hex");
    putc(&mut ops, b'\n' as i64);
    ops.extend([
        Op::Label("jit_done".into()),
        // restore sie from the spare slot — SP+96 is the caller's s0 (reloaded
        // into s0 below), the saved sie lives at SP+112.
        ld(T0, SP, 112),
        Op::Csrrw {
            rd: X0,
            csr: encode::CSR_SIE,
            rs: T0,
        },
        ld(RA, SP, 104),
        ld(S0, SP, 96),
        ld(S1, SP, 88),
        ld(S2, SP, 80),
        ld(S3, SP, 72),
        ld(S4, SP, 64),
        ld(S5, SP, 56),
        ld(S6, SP, 48),
        ld(S7, SP, 40),
        ld(S8, SP, 32),
        ld(S9, SP, 24),
        ld(S10, SP, 16),
        ld(S11, SP, 8),
        ld(TP, SP, 0),
        addi(SP, SP, 120),
        ret(),
        Op::Label("jit_noimg".into()),
    ]);
    puts(&mut ops, "WASM-JIT-NOIMG\n");
    ops.push(j("jit_done"));
    ops.extend([
        Op::Label("jit_trap_badfunc".into()),
        li(A0, i64::from(jc::TRAP_BADFUNC)),
        j("jit_trap"),
    ]);
    ops
}

/// `JitAx(a0=slot) -> a0` — AX-trailer funcidx lookup. Returns the funcidx for
/// an `AX_*` slot, or -1 when the AX block or that slot is absent (`u32::MAX`
/// sign-extends to -1). Read on demand from `__jit_in` — a cold path used only
/// at listener-registration and asyncify-schedule time.
fn jit_ax_node() -> Vec<Op> {
    vec![
        Op::Comment("JitAx — AX-trailer funcidx lookup: a0=slot → a0=funcidx|-1".into()),
        Op::Glob("JitAx".into()),
        Op::Label("JitAx".into()),
        la(T0, Addr::JitHdr),
        li(T1, i64::from(OFF_AXB)),
        add(T1, T0, T1),
        ld(T1, T1, 0), // axb = *(jit_hdr + OFF_AXB)
        beq(T1, X0, "jit_ax_none"),
        lw(T2, T1, 0),
        li(T3, i64::from(jc::AMETA_MAGIC)),
        bne(T2, T3, "jit_ax_none"),
        lw(T2, T1, 4), // AX_COUNT
        bgeu(A0, T2, "jit_ax_none"),
        slli(A0, A0, 2),
        add(T1, T1, A0),
        lw(A0, T1, 8), // funcidx
        ret(),
        Op::Label("jit_ax_none".into()),
        li(A0, -1),
        ret(),
    ]
}

/// `JitCall(a0=funcidx, a1=nargs, a2..a5=args) -> a0` — re-enter a translated
/// cell function. Re-establishes the jit execution context (s8/s9/s10/s11, fuel,
/// state), parks a trap continuation (`OFF_RESUME`/`OFF_SPSAVE`) so a fault deep
/// in the call unwinds back to this frame, pushes `nargs` 8-byte cells onto the
/// value stack, `jalr`s `ftab[funcidx]`, and returns the top result cell (-1 on
/// trap). Runs *between* `JitRun`s — input listeners and the asyncify rewind —
/// never inside an active run (the value-stack base reset would clobber a live
/// frame). Working state rides the frame, not s-regs, because generated code
/// owns s8-s11.
fn jit_call_node() -> Vec<Op> {
    vec![
        Op::Comment(
            "JitCall — re-entrant funcidx invoke: a0=funcidx a1=nargs a2..a5=args \
             → a0=top result cell, -1 on trap"
                .into(),
        ),
        Op::Glob("JitCall".into()),
        Op::Label("JitCall".into()),
        addi(SP, SP, -128),
        sd(RA, SP, 120),
        sd(S8, SP, 112),
        sd(S9, SP, 104),
        sd(S10, SP, 96),
        sd(S11, SP, 88),
        sd(TP, SP, 80),
        sd(A0, SP, 72),
        sd(A1, SP, 64),
        sd(A2, SP, 56),
        sd(A3, SP, 48),
        sd(A4, SP, 40),
        sd(A5, SP, 32),
        // re-establish the jit execution context for a top-level call
        la(S9, Addr::JitHdr),
        la(S8, Addr::WasmMem),
        la(S10, Addr::JitStk),
        mv(S11, S10),
        li(T0, FUEL),
        sd(T0, S9, OFF_FUEL),
        li(T0, STATE_OK),
        sd(T0, S9, OFF_STATE),
        sd(X0, S9, OFF_ERR),
        // trap continuation → jit_call_done; restore sp → this frame. Both are
        // large offsets, so the header slot is addressed via li+add.
        li(T0, i64::from(OFF_SPSAVE)),
        add(T0, S9, T0),
        sd(SP, T0, 0),
        la(T0, Addr::Label("jit_call_done".into())),
        li(T1, i64::from(OFF_RESUME)),
        add(T1, S9, T1),
        sd(T0, T1, 0),
        // push nargs arg cells onto the value stack (arg_i at SP+56+i*8)
        sd(X0, SP, 24),
        Op::Label("jit_call_args".into()),
        ld(T0, SP, 24),
        ld(T1, SP, 64),
        bgeu(T0, T1, "jit_call_go"),
        slli(T0, T0, 3),
        add(T1, SP, T0),
        ld(T2, T1, 56),
        sd(T2, S10, 0),
        addi(S10, S10, 8),
        ld(T0, SP, 24),
        addi(T0, T0, 1),
        sd(T0, SP, 24),
        j("jit_call_args"),
        Op::Label("jit_call_go".into()),
        // t6 = ftab[funcidx]
        ld(T0, SP, 72),
        slli(T0, T0, 3),
        addi(T0, T0, OFF_FTAB),
        add(T0, S9, T0),
        ld(T6, T0, 0),
        Op::Jalr {
            rd: RA,
            rs: T6,
            imm: 0,
        },
        Op::Label("jit_call_done".into()),
        // STATE != OK → a trap fired mid-call (jit_trap resumed here).
        ld(T0, S9, OFF_STATE),
        li(T1, STATE_OK),
        bne(T0, T1, "jit_call_err"),
        ld(T0, S10, -8), // top result cell
        sd(T0, SP, 16),
        j("jit_call_out"),
        Op::Label("jit_call_err".into()),
        li(T0, -1),
        sd(T0, SP, 16),
        Op::Label("jit_call_out".into()),
        ld(A0, SP, 16),
        ld(RA, SP, 120),
        ld(S8, SP, 112),
        ld(S9, SP, 104),
        ld(S10, SP, 96),
        ld(S11, SP, 88),
        ld(TP, SP, 80),
        addi(SP, SP, 128),
        ret(),
    ]
}

/// All guest-JIT nodes in one `Purpose::WasmJit` node. `with_ext` includes
/// the import-trampoline table (`Wasm*` routines exist only under
/// `dom::attach`, i.e. `kernel.wasm.jit`).
pub fn nodes(with_ext: bool) -> Vec<Node> {
    let mut ops = vec![Op::Comment(
        "guest JIT — translate __jit_in → __jit_code, fence.i, execute. \
         s8=wasm_mem s9=jit_hdr s10=vsp s11=fp; s4=jit_in s5=code s6=cursor s7=slot0"
            .into(),
    )];
    ops.extend(jit_em_node());
    ops.extend(jit_emi_node());
    ops.extend(jit_ems_node());
    ops.extend(jit_lia_node());
    ops.extend(jit_h_nop());
    ops.extend(jit_h_const());
    ops.extend(jit_h_lget());
    ops.extend(jit_h_lset());
    ops.extend(jit_h_ltee());
    ops.extend(jit_h_drop());
    ops.extend(jit_h_alu("jit_h_i32alu", "jit_i32_pool"));
    ops.extend(jit_h_alu("jit_h_i64alu", "jit_i64_pool"));
    ops.extend(jit_h_cmp());
    ops.extend(jit_h_jmp());
    ops.extend(jit_h_jz());
    ops.extend(jit_h_jnz());
    ops.extend(jit_h_ret());
    ops.extend(jit_h_call());
    ops.extend(jit_h_load());
    ops.extend(jit_h_store());
    ops.extend(jit_h_gget());
    ops.extend(jit_h_gset());
    ops.extend(jit_h_memsize());
    ops.extend(jit_h_memgrow());
    ops.extend(jit_h_select());
    ops.extend(jit_h_div("jit_h_i32div", "jit_i32div_pool", true));
    ops.extend(jit_h_div("jit_h_i64div", "jit_i64div_pool", false));
    ops.extend(jit_h_rot(
        "jit_h_i32rot",
        encode::sllw(T2, T0, T1),
        encode::srlw(T2, T0, T1),
        encode::sllw(T3, T0, T3),
        encode::srlw(T3, T0, T3),
        31,
        32,
    ));
    ops.extend(jit_h_rot(
        "jit_h_i64rot",
        encode::sll(T2, T0, T1),
        encode::srl(T2, T0, T1),
        encode::sll(T3, T0, T3),
        encode::srl(T3, T0, T3),
        63,
        64,
    ));
    // M3 integer/control coverage.
    ops.extend(jit_h_brtbl());
    ops.extend(jit_h_memfill());
    ops.extend(jit_h_memcopy());
    ops.extend(jit_h_calli());
    ops.extend(jit_rt_calli_node());
    ops.extend(jit_h_clz());
    ops.extend(jit_h_ctz());
    ops.extend(jit_h_popcnt());
    ops.extend(jit_h_sext());
    ops.extend(jit_h_memgrow2());
    ops.extend(jit_h_fpalu());
    ops.extend(jit_h_fpcmp());
    ops.extend(jit_h_fpcvt());
    if with_ext {
        ops.extend(jit_h_ext());
    } else {
        ops.extend(vec![
            Op::Label("jit_h_ext".into()),
            li(A0, i64::from(jc::TRAP_EXT)),
            j("jit_trap"),
        ]);
    }
    ops.extend(jit_h_trap());
    ops.extend(jit_memcpy_node());
    // literal pools + tables (data — each guarded by a jump-over)
    word_pool(
        &mut ops,
        "jit_i32_pool",
        &[
            encode::addw(T0, T0, T1),
            encode::subw(T0, T0, T1),
            encode::mulw(T0, T0, T1),
            encode::and_(T0, T0, T1),
            encode::or_(T0, T0, T1),
            encode::xor(T0, T0, T1),
            encode::sllw(T0, T0, T1),
            encode::sraw(T0, T0, T1),
            encode::srlw(T0, T0, T1),
        ],
    );
    word_pool(
        &mut ops,
        "jit_i64_pool",
        &[
            encode::add(T0, T0, T1),
            encode::sub(T0, T0, T1),
            encode::mul(T0, T0, T1),
            encode::and_(T0, T0, T1),
            encode::or_(T0, T0, T1),
            encode::xor(T0, T0, T1),
            encode::sll(T0, T0, T1),
            encode::sra(T0, T0, T1),
            encode::srl(T0, T0, T1),
        ],
    );
    word_pool(
        &mut ops,
        "jit_i32div_pool",
        &[
            encode::divw(T0, T0, T1),
            encode::divuw(T0, T0, T1),
            encode::remw(T0, T0, T1),
            encode::remuw(T0, T0, T1),
        ],
    );
    word_pool(
        &mut ops,
        "jit_i64div_pool",
        &[
            encode::div(T0, T0, T1),
            encode::divu(T0, T0, T1),
            encode::rem(T0, T0, T1),
            encode::remu(T0, T0, T1),
        ],
    );
    // CMP recipe pool: 8 words per subop, zero-terminated.
    {
        let z = [
            encode::slli(T0, T0, 32),
            encode::srli(T0, T0, 32),
            encode::slli(T1, T1, 32),
            encode::srli(T1, T1, 32),
        ];
        let xor = encode::xor(T0, T0, T1);
        let seqz = encode::sltiu(T0, T0, 1);
        let snez = encode::sltu(T0, X0, T0);
        let slt_f = encode::slt(T0, T0, T1);
        let sltu_f = encode::sltu(T0, T0, T1);
        let slt_s = encode::slt(T0, T1, T0);
        let sltu_s = encode::sltu(T0, T1, T0);
        let mut entries: Vec<Vec<u32>> = vec![
            vec![xor, seqz],
            vec![xor, snez],
            vec![slt_f],
            [z.to_vec(), vec![sltu_f]].concat(),
            vec![slt_s],
            [z.to_vec(), vec![sltu_s]].concat(),
            vec![slt_s, seqz],
            [z.to_vec(), vec![sltu_s, seqz]].concat(),
            vec![slt_f, seqz],
            [z.to_vec(), vec![sltu_f, seqz]].concat(),
        ];
        entries.extend([
            vec![xor, seqz],
            vec![xor, snez],
            vec![slt_f],
            vec![sltu_f],
            vec![slt_s],
            vec![sltu_s],
            vec![slt_s, seqz],
            vec![sltu_s, seqz],
            vec![slt_f, seqz],
            vec![sltu_f, seqz],
        ]);
        entries.push(vec![seqz]); // i32.eqz
        entries.push(vec![seqz]); // i64.eqz
        ops.push(j("jit_cmp_recipes_over"));
        ops.push(Op::Label("jit_cmp_recipes".into()));
        for e in &entries {
            let mut v = e.clone();
            v.resize(8, 0);
            for w in v {
                ops.push(Op::Word(w));
            }
        }
        ops.push(Op::Label("jit_cmp_recipes_over".into()));
    }
    // dispatch table (Dw64) — order must match jcode::R_*.
    {
        let names = [
            "jit_h_nop",
            "jit_h_const",
            "jit_h_lget",
            "jit_h_lset",
            "jit_h_ltee",
            "jit_h_drop",
            "jit_h_i32alu",
            "jit_h_i64alu",
            "jit_h_cmp",
            "jit_h_jmp",
            "jit_h_jz",
            "jit_h_jnz",
            "jit_h_ret",
            "jit_h_call",
            "jit_h_load",
            "jit_h_store",
            "jit_h_gget",
            "jit_h_gset",
            "jit_h_memsize",
            "jit_h_memgrow",
            "jit_h_ext",
            "jit_h_trap",
            "jit_h_select",
            "jit_h_i32div",
            "jit_h_i64div",
            "jit_h_i32rot",
            "jit_h_i64rot",
            "jit_h_brtbl",
            "jit_h_memfill",
            "jit_h_memcopy",
            "jit_h_calli",
            "jit_h_clz",
            "jit_h_ctz",
            "jit_h_popcnt",
            "jit_h_sext",
            "jit_h_memgrow2",
            "jit_h_fpalu",
            "jit_h_fpcmp",
            "jit_h_fpcvt",
        ];
        ops.push(j("jit_disp_over"));
        ops.push(Op::Label("jit_disp".into()));
        for n in names {
            ops.push(Op::Dw64 {
                addr: Addr::Label(n.into()),
            });
        }
        ops.push(Op::Label("jit_disp_over".into()));
    }
    if with_ext {
        ops.push(j("jit_ext_over"));
        ops.push(Op::Label("jit_ext_tab".into()));
        for l in [
            "WasmLog",
            "WasmDomText",
            "WasmDomVisible",
            "LwFetch",
            "WasmAwait",
            "WasmThrow",
            "WasmCatch",
            // M3d libwasm handle-ABI bridge (EXT_SETPROP..EXT_ADDSTR).
            "LwSetProp",
            "LwCreateEl",
            "LwAppend",
            "LwAwaitSup",
            "LwAwaitVoid",
            "LwAwaitVal",
            "LwGetRoot",
            "LwAddLsn",
            "LwRemove",
            "LwAddStr",
            // `__ev_obj` event-property bridge (EXT_EVGET / EXT_EVCALL).
            "LwEvGet",
            "LwEvCall",
        ] {
            ops.push(Op::Dw64 {
                addr: Addr::Label(l.into()),
            });
        }
        ops.push(Op::Label("jit_ext_over".into()));
    }
    ops.extend(jit_trap_node());
    ops.extend(jit_run_node());
    ops.extend(jit_ax_node());
    ops.extend(jit_call_node());
    vec![Node {
        purpose: Purpose::WasmJit,
        ops,
    }]
}

/// `__jit_code` arena bytes for an image: one slot per record + a prologue
/// headroom per function, bounded by `MAX_JIT_CODE_BYTES`. `JitRun` derives
/// the same bound from the image header at runtime (`OFF_CODE_END`), so the
/// emit cursor can never run past the allocated arena.
pub fn code_arena_bytes(nfuncs: u64, nrecs: u64) -> u64 {
    // Per-func slack 128B covers the fixed prologue + the bounded local-zero
    // loop (~25 words); records use one SLOT_BYTES slot each.
    (nrecs * SLOT_BYTES + nfuncs * 128 + 4096).min(jc::MAX_JIT_CODE_BYTES)
}

/// Read `(nfuncs, nrecords, mem_pages)` from a `__jit_in` image, or `None`
/// when it is absent/short/bad-magic — an empty image is legal (JitRun
/// reports `WASM-JIT-NOIMG`).
fn img_dims(img: &[u8]) -> Option<(u64, u64, u64)> {
    if img.len() < jc::HDR_BYTES {
        return None;
    }
    let w = |o: usize| u32::from_le_bytes(img[o..o + 4].try_into().unwrap()) as u64;
    if img[..4] != jc::MAGIC.to_le_bytes() {
        return None;
    }
    Some((
        w(jc::OFF_NFUNCS as usize),
        w(jc::OFF_NRECORDS as usize),
        w(jc::OFF_MEM_PAGES as usize),
    ))
}

/// Attach the guest-JIT substrate to `m`: `__jit_in` rodata (may be empty —
/// JitRun then prints `WASM-JIT-NOIMG`), the `__jit*`/`__wasm_mem` BSS
/// regions, and the translator/executor node. The caller supplies the
/// predecoded image (`g6b_wasm::jcode::encode`) — this crate cannot depend
/// on the decoder.
pub fn attach(m: &mut Module, img: &[u8]) {
    m.jit_in = img.to_vec();
    m.jit_bytes = JIT_HDR_BYTES;
    m.jit_stk_bytes = jc::JIT_STK_BYTES;
    let (nf, nr, pages) = img_dims(img).unwrap_or((0, 0, 0));
    m.jit_code_bytes = code_arena_bytes(nf, nr);
    // `+KGET_TAIL_BYTES` reserves the `libwasm_await_value` string pool and the
    // `__asyncify_data` unwind scratch past the cell's declared `mem_pages`
    // (see `__kget`/`LwAwaitVoid`/`LwAwaitVal`).
    m.wasm_mem_bytes = pages * 65536 + crate::kget::KGET_TAIL_BYTES;
    for n in nodes(true) {
        m.push(n);
    }
}

/// Install a real predecoded image into an already-attached module —
/// replaces the `__jit_in` bytes and grows the code/memory arenas. Called
/// from `g6b-elf::payload_module` via `g6b_wasm::jcode::install_guest`.
pub fn set_image(m: &mut Module, img: &[u8]) -> Result<(), String> {
    let (nf, nr, pages) = img_dims(img).ok_or_else(|| "jcode: bad __jit_in image".to_string())?;
    if nf > jc::MAX_JIT_FUNCS as u64 || nr > jc::MAX_JIT_RECORDS as u64 {
        return Err("jcode: image exceeds jit bounds".into());
    }
    m.jit_in = img.to_vec();
    m.jit_code_bytes = code_arena_bytes(nf, nr);
    m.wasm_mem_bytes = pages * 65536 + crate::kget::KGET_TAIL_BYTES;
    Ok(())
}
