// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Functional execution of an AI-island descriptor against guest memory.
//!
//! Q6 needs the island to be *functional*, not merely bookkeeping: an in-guest runtime
//! that submits a GEMM descriptor and then compares `C` against a golden must actually
//! find `C` in memory. Until it does, every in-guest test degenerates into "did the
//! completion word appear", which passes on a device that computes nothing.
//!
//! What this module models, and what it deliberately does not:
//!
//! | Modelled | Not modelled |
//! |---|---|
//! | `C = A · B` with the design's operand types and leading dimensions | the PE array, banking, or oct-drain |
//! | the shape bound the engine enforces, and the status it returns | cycles, bandwidth, or any latency |
//! | refusal of arithmetic modes the capability window does not grant | the modes themselves |
//!
//! Every code and bound is read from the ingested [`AiIslandModel`]: op codes, status
//! codes, the accumulator tile that bounds each dimension, and the granted data types.
//! A literal here would be a second source of truth for the descriptor ABI, which is the
//! failure this package exists to prevent (`../AGENTS.md` §1.2).
//!
//! # Why the writes are returned rather than performed
//!
//! The island lives inside [`PhysMem`], so a method that both borrowed the device and
//! wrote guest memory could not typecheck. The same shape is already used by
//! `AiIsland::queue_qfence`: compute the writes, hand them to the caller, let the caller
//! own the mutable borrow.

use crate::mem::PhysMem;
use crate::numfmt::{pack_c, read_elem, row_bytes, Elem, NumFmt};
use g6q_core::model::AiIslandModel;
use g6q_diag::ai_tensor::AiTensorEvent;

/// Status-code names this module resolves from the ingested descriptor package.
///
/// Named here so that a package which renames a status surfaces as an unresolved lookup
/// rather than as a silently wrong completion code.
const ST_OK: &str = "ST_OK";
const ST_ERR: &str = "ST_ERR";
const ST_BAD_VER: &str = "ST_BAD_VER";
const ST_BAD_OP: &str = "ST_BAD_OP";
/// Distinct from `ST_ERR` so a guest can tell "this engine cannot do BF16" from a generic
/// failure and fall back deliberately. Resolved optionally: a package predating the status
/// falls back to `ST_ERR` rather than inventing a code.
const ST_BAD_FMT: &str = "ST_BAD_FMT";

/// Op-code name for the dense matrix-multiply the engine implements.
const OP_GEMM: &str = "OP_GEMM";

/// The outcome of executing one descriptor.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AiJobResult {
    /// Completion status, resolved from the ingested status table.
    pub status: u16,
    /// `C` writes the island would perform, as `(guest address, little-endian i32)`.
    ///
    /// Empty for an op this model does not execute, or for any rejected descriptor.
    /// The caller applies them; see the module note on borrowing.
    pub c_writes: Vec<(u64, i32)>,
    /// True when the descriptor named an op the engine accepts but this backend does not
    /// execute (for example a layout transform). The entry still completes `ST_OK`, but a
    /// consumer can tell "ran" from "accepted and skipped".
    pub skipped: bool,
}

/// Why a descriptor was refused, for callers that want to explain a status.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AiJobReject {
    /// `version` did not match the version the package declares.
    BadVersion,
    /// `op` is not an op the package names.
    BadOp,
    /// A dimension was zero, exceeded the accumulator tile, or a leading dimension was
    /// smaller than the extent it must span. This is the engine's own `ST_CHK`.
    BadShape,
    /// The descriptor requested an arithmetic mode the capability window does not grant.
    UngrantedDtype,
}

impl AiJobReject {
    /// Stable wire name, for traces and reports.
    pub fn as_str(self) -> &'static str {
        match self {
            AiJobReject::BadVersion => "bad-version",
            AiJobReject::BadOp => "bad-op",
            AiJobReject::BadShape => "bad-shape",
            AiJobReject::UngrantedDtype => "ungranted-dtype",
        }
    }
}

fn status_of(model: &AiIslandModel, name: &str, fallback: u16) -> u16 {
    model
        .desc_layout
        .status(name)
        .map_or(fallback, |v| v as u16)
}

/// Decode `ld_ab` into `(lda, ldb)`.
///
/// The packing is stated by the descriptor package as `lda | (ldb << 16)`. It is a field
/// *encoding*, not an address, so it is read here rather than ingested as an offset.
fn split_ld(ld_ab: u32) -> (u32, u32) {
    (ld_ab & 0xffff, ld_ab >> 16)
}

/// Whether the descriptor asks for an arithmetic mode beyond dense 8-bit.
///
/// Returns `None` when the flags layout is unresolved, which means the request cannot be
/// characterised at all. Refusing in that case would reject every descriptor on a package
/// that does not publish the layout, so the caller treats `None` as "no claim made".
fn requests_ungranted_mode(model: &AiIslandModel, flags: u32) -> Option<bool> {
    let fl = model.desc_layout.flags_layout?;
    // A combined comment span mixes dtype/accmode/ew/sp24 into one blob. Reading it as a
    // mode would be a plausible-looking wrong answer, so make no claim (F10).
    if fl.dtype_combined {
        return None;
    }
    let ew = fl.ew.map(|f| f.extract(flags)).unwrap_or(0);
    let sp24 = fl.sp24_bit.map(|b| (flags >> b) & 1).unwrap_or(0);
    let dtype = (flags >> fl.dtype_shift) & fl.dtype_mask;
    // `dtype_mask` in the capability window is a grant bitmap; bit 0 is dense 8-bit.
    // A part that grants nothing beyond bit 0 cannot honour `ew`/`sp24`.
    let granted = model.config.dtype_mask.unwrap_or(1);
    let sub_byte_or_sparse = ew != 0 || sp24 != 0;
    if sub_byte_or_sparse && (granted & !1) == 0 {
        return Some(true);
    }
    // `dtype` selects signedness of the operands, which this backend implements only for
    // the signed/signed encoding the golden uses.
    Some(dtype != 0 && (granted & !1) == 0)
}

/// Resolve the numeric format a descriptor requests, and check it is granted.
///
/// Three distinguishable outcomes, because collapsing them would hide the interesting one:
///
/// * `Ok(fmt)` — the request is resolved and granted.
/// * `Err(UngrantedDtype)` — resolved but not in the capability window's mask, or a value the
///   ABI reserves. Both are refusals; neither may fall back to INT8.
/// * `Ok(NumFmt::Int)` when the package does not publish the field at all — the request
///   cannot be characterised, so the only honest reading is the all-zero legacy one, which
///   *is* integer. Executing float arithmetic on an unresolved layout would mean guessing an
///   operand encoding.
fn resolve_numfmt(model: &AiIslandModel, flags: u32) -> Result<NumFmt, AiJobReject> {
    let Some(fl) = model.desc_layout.flags_layout else {
        return Ok(NumFmt::Int);
    };
    let Some(field) = fl.numfmt else {
        return Ok(NumFmt::Int);
    };
    let raw = field.extract(flags);
    let fmt = NumFmt::from_abi(raw).ok_or(AiJobReject::UngrantedDtype)?;
    // Absent a published mask, assume the frozen baseline: dense INT8 only. Assuming
    // everything is granted would make the emulator compute formats the design refuses,
    // which is the one divergence that cannot be caught by comparing results.
    let granted = model.config.dtype_mask.unwrap_or(1);
    if (granted >> fmt.grant_bit()) & 1 == 0 {
        return Err(AiJobReject::UngrantedDtype);
    }
    Ok(fmt)
}

/// Execute one descriptor image against guest memory.
///
/// `ev` is the descriptor already read from memory by
/// `AiIsland::read_descriptor_event`, so this function never re-decodes the layout.
///
/// The checks mirror the engine's own order — version, op, shape — so a status returned
/// here is the status the design would return, not an emulator opinion.
pub fn execute(mem: &PhysMem, ev: &AiTensorEvent, model: &AiIslandModel) -> AiJobResult {
    match plan(mem, ev, model) {
        Ok(r) => r,
        Err((reject, status)) => {
            let _ = reject;
            AiJobResult {
                status,
                c_writes: Vec::new(),
                skipped: false,
            }
        }
    }
}

/// Execute one descriptor, reporting why it was refused when it was.
pub fn plan(
    mem: &PhysMem,
    ev: &AiTensorEvent,
    model: &AiIslandModel,
) -> Result<AiJobResult, (AiJobReject, u16)> {
    let ok = status_of(model, ST_OK, 0);

    // ---- version -------------------------------------------------------------------
    // `None` means the package does not name a version; the device's own fallback
    // already reports that, so this path makes no additional claim.
    if let Some(want) = model.desc_layout.version {
        if ev.version as u64 != want {
            return Err((AiJobReject::BadVersion, status_of(model, ST_BAD_VER, 2)));
        }
    }

    // ---- op ------------------------------------------------------------------------
    // An op the package does not name at all is refused; an op it names but this backend
    // does not execute completes without touching memory.
    let named = model.desc_layout.ops.values().any(|v| *v == ev.op as u64);
    if !named {
        return Err((AiJobReject::BadOp, status_of(model, ST_BAD_OP, 3)));
    }
    let gemm = model.desc_layout.op(OP_GEMM);
    if gemm != Some(ev.op as u64) {
        return Ok(AiJobResult {
            status: ok,
            c_writes: Vec::new(),
            skipped: true,
        });
    }

    // ---- arithmetic mode -------------------------------------------------------------
    // Two checks, not one. `requests_ungranted_mode` covers the legacy `ew`/`sp24`/`dtype`
    // levers; `resolve_numfmt` covers the numeric-format field. Both must refuse, because a
    // descriptor can express an ungranted mode either way and demoting silently to INT8
    // would return numerically plausible results for the wrong arithmetic.
    if requests_ungranted_mode(model, ev.flags) == Some(true) {
        return Err((AiJobReject::UngrantedDtype, status_of(model, ST_ERR, 1)));
    }
    let fmt = match resolve_numfmt(model, ev.flags) {
        Ok(f) => f,
        Err(why) => {
            // Prefer the design's own ST_BAD_FMT when the package publishes it, so the guest
            // can tell "cannot do BF16" from a generic error and choose a fallback.
            let st = model
                .desc_layout
                .status(ST_BAD_FMT)
                .map_or_else(|| status_of(model, ST_ERR, 1), |v| v as u16);
            return Err((why, st));
        }
    };

    // ---- shape -----------------------------------------------------------------------
    // The engine bounds every dimension by the corresponding accumulator tile and rejects
    // anything larger; software owns blocking beyond it. That is a descriptor-level
    // contract, so it is enforced here rather than silently streamed (F12).
    let (m, n, k) = (ev.m as u64, ev.n as u64, ev.k as u64);
    let (lda, ldb) = split_ld(ev.ld_ab);
    let (tm, tn, tk) = (
        model.config.acc_tile_m as u64,
        model.config.acc_tile_n as u64,
        model.config.acc_tile_k as u64,
    );
    let over_tile = |dim: u64, tile: u64| tile != 0 && dim > tile;
    if m == 0
        || n == 0
        || k == 0
        || over_tile(m, tm)
        || over_tile(n, tn)
        || over_tile(k, tk)
        || (lda as u64) < k
        // AI-X9: B is k-major, so ldb must hold a row of k elements (was n).
        || (ldb as u64) < k
    {
        return Err((AiJobReject::BadShape, status_of(model, ST_ERR, 1)));
    }

    // ---- compute ---------------------------------------------------------------------
    //   C[i,j] (i32) = sum_t A[i,t] * B[j,t]
    //
    // AI-X9 (descriptor ContractVersion 2): A is row-major [m][k] and B is **k-major**
    // [n][k]. Both stride their row index (`lda` strides i, `ldb` strides j) and both run
    // contiguously along the reduction axis t. That symmetry is the point: it is what makes
    // a sub-byte format expressible, because two INT4 elements packed in one byte are
    // consecutive t and therefore feed the same C[i,j] accumulator. It is also the layout a
    // framework already has -- torch.nn.Linear.weight is [n, k] row-major.
    // See architecture/ai-matrix/numeric-formats-datapath.md §8.
    // A read the guest memory map cannot satisfy is an error, not a zero: silently
    // reading zero would produce a wrong C that still looks like a successful job.
    // Leading dimensions count ELEMENTS, so a row's byte extent depends on the format: a
    // packed INT4 row spans half the bytes of the same-length INT8 row, and an FP32 row four
    // times as many. Striding by elements would silently overlap or gap the rows.
    let a_row_stride = row_bytes(fmt, lda as u64);
    let b_row_stride = row_bytes(fmt, ldb as u64);

    let mut c_writes = Vec::with_capacity((m * n) as usize);
    let bad = |model: &AiIslandModel| (AiJobReject::BadShape, status_of(model, ST_ERR, 1));
    for i in 0..m {
        let a_row = ev.ptr_a.wrapping_add(i.wrapping_mul(a_row_stride));
        for j in 0..n {
            // One accumulator per kind. Integer modes sum in i32 and float modes in f32,
            // matching the 32-bit `C` the ABI defines; see the numfmt module note on why a
            // wider accumulator would make the model less useful as a golden, not more.
            let mut acc_i: i32 = 0;
            let mut acc_f: f32 = 0.0;
            for t in 0..k {
                let rd = |addr: u64| mem.read_le::<1>(addr).ok().map(|v| v as u8);
                let a = read_elem(fmt, a_row, t, rd).ok_or_else(|| bad(model))?;
                // B is k-major, so its row base is fixed by `j` for the whole reduction and
                // the element index within the row is `t` -- exactly like A. `read_elem` is
                // index-based and needs no change for either operand or any format.
                let b_row = ev.ptr_b.wrapping_add(j.wrapping_mul(b_row_stride));
                let b = read_elem(fmt, b_row, t, rd).ok_or_else(|| bad(model))?;
                match (a, b) {
                    (Elem::Int(x), Elem::Int(y)) => {
                        acc_i = acc_i.wrapping_add(x.wrapping_mul(y));
                    }
                    (Elem::Float(x), Elem::Float(y)) => {
                        acc_f += x * y;
                    }
                    // read_elem derives the element kind from `fmt` alone, so a mixed pair is
                    // structurally impossible. Refuse rather than pick one: a silent choice
                    // here would be an arithmetic error dressed as a result.
                    _ => return Err(bad(model)),
                }
            }
            let c_addr = ev
                .ptr_c
                .wrapping_add(i.wrapping_mul(n).wrapping_add(j).wrapping_mul(4));
            c_writes.push((c_addr, if fmt.is_float() { pack_c(acc_f) } else { acc_i }));
        }
    }

    Ok(AiJobResult {
        status: ok,
        c_writes,
        skipped: false,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mem::{PhysMem, Region};
    use g6q_core::model::{AiDescLayout, AiIslandConfig, DescField};

    const BASE: u64 = 0x8000_0000;

    fn layout() -> AiDescLayout {
        let mut l = AiDescLayout {
            desc_bytes: 64,
            version: Some(1),
            ..Default::default()
        };
        let mut f = |name: &str, offset: u64, size: u64| {
            l.fields.insert(
                name.into(),
                DescField {
                    offset,
                    size,
                    bit_low: offset * 8,
                    bit_high: offset * 8 + size * 8 - 1,
                },
            );
        };
        f("version", 0x00, 2);
        f("op", 0x02, 2);
        f("flags", 0x04, 4);
        f("m", 0x08, 4);
        f("n", 0x0c, 4);
        f("k", 0x10, 4);
        f("ld_ab", 0x14, 4);
        f("ptr_a", 0x18, 8);
        f("ptr_b", 0x20, 8);
        f("ptr_c", 0x28, 8);
        f("ptr_scale", 0x30, 8);
        f("ptr_done", 0x38, 8);
        l.ops.insert("OP_GEMM".into(), 1);
        l.ops.insert("OP_CONV2D".into(), 2);
        l.ops.insert("OP_LAYOUT".into(), 3);
        l.statuses.insert("ST_OK".into(), 0);
        l.statuses.insert("ST_ERR".into(), 1);
        l.statuses.insert("ST_BAD_VER".into(), 2);
        l.statuses.insert("ST_BAD_OP".into(), 3);
        l.statuses.insert("ST_BAD_FMT".into(), 8);
        l
    }

    /// The published flags layout, including `numfmt` at `flags[22:20]`.
    fn flags_layout() -> g6q_core::model::DescFlagsLayout {
        use g6q_core::model::{DescFlagsLayout, FlagField};
        DescFlagsLayout {
            dtype_shift: 8,
            dtype_mask: 0x3,
            priority_shift: 16,
            priority_mask: 0xf,
            irq_bit: 2,
            dtype_combined: false,
            accmode: Some(FlagField {
                shift: 10,
                mask: 0x3,
            }),
            ew: Some(FlagField {
                shift: 12,
                mask: 0x3,
            }),
            sp24_bit: Some(14),
            numfmt: Some(FlagField {
                shift: 20,
                mask: 0x7,
            }),
        }
    }

    /// A model whose capability window grants `mask` and publishes the flags layout.
    ///
    /// Used to model a SKU whose datapath implements more than dense INT8. Raising the mask
    /// here is legitimate *in the model*; on real hardware the island asserts
    /// grant ⊆ `AiIslandPeImplMask`, so a design cannot advertise what its PE cannot do.
    fn model_granting(mask: u32) -> AiIslandModel {
        let mut m = model(256);
        m.config.dtype_mask = Some(mask);
        m.desc_layout.flags_layout = Some(flags_layout());
        m
    }

    fn all_formats_granted() -> u32 {
        0xff
    }

    fn model(tile: u32) -> AiIslandModel {
        AiIslandModel {
            config: AiIslandConfig {
                queues: 1,
                queue_depth: 4,
                acc_tile_m: tile,
                acc_tile_n: tile,
                acc_tile_k: tile,
                dtype_mask: Some(1),
                ..Default::default()
            },
            desc_layout: layout(),
            ..Default::default()
        }
    }

    /// A 2x2x2 signed INT8 GEMM, laid out the way the descriptor describes it.
    fn fixture() -> (PhysMem, AiTensorEvent) {
        let mut mem = PhysMem::new();
        mem.add(Region::new(BASE, 0x1000));
        // A = [[1, 2], [3, 4]] at +0x100, row-major, lda = 2
        // B = [[5, 6], [7, 8]] logically; AI-X9 stores it **k-major**, so the bytes are
        // B'[j][t] = B[t][j] = 5, 7, 6, 8 at +0x200 with ldb = k = 2.
        // C = A*B = [[19, 22], [43, 50]] at +0x300 -- unchanged, because only B's storage
        // moved, not the product.
        for (off, v) in [(0u64, 1i8), (1, 2), (2, 3), (3, 4)] {
            mem.write_le::<1>(BASE + 0x100 + off, v as u8 as u64)
                .unwrap();
        }
        for (off, v) in [(0u64, 5i8), (1, 7), (2, 6), (3, 8)] {
            mem.write_le::<1>(BASE + 0x200 + off, v as u8 as u64)
                .unwrap();
        }
        let ev = AiTensorEvent {
            version: 1,
            op: 1,
            m: 2,
            n: 2,
            k: 2,
            ld_ab: 2 | (2 << 16),
            ptr_a: BASE + 0x100,
            ptr_b: BASE + 0x200,
            ptr_c: BASE + 0x300,
            ..Default::default()
        };
        (mem, ev)
    }

    /// A 2x2x2 GEMM over `fmt`, with A = B = [[1,2],[3,4]] written in that format, so the
    /// golden is [[7,10],[15,22]] regardless of encoding.
    ///
    /// Reusing one matrix across every format is the point: it makes the formats *comparable*.
    /// A per-format fixture could hide a decode bug behind a per-format golden.
    ///
    /// The operands are deliberately 1..4. Signed INT4 spans only -8..7, so the more obvious
    /// B = [[5,6],[7,8]] silently wraps 8 to -8 and yields 1*6 + 2*(-8) = -10 instead of 22 —
    /// a wrong answer that looks like an arithmetic bug rather than an unrepresentable
    /// operand. Every value here is exact in INT4, both FP8 variants, FP16, BF16 and FP32,
    /// and the encoders below assert that rather than trusting it.
    fn fixture_fmt(fmt: NumFmt) -> (PhysMem, AiTensorEvent) {
        let mut mem = PhysMem::new();
        mem.add(Region::new(BASE, 0x1000));
        let a = [1.0f32, 2.0, 3.0, 4.0];
        // B is logically [[1,2],[3,4]] but stored k-major (AI-X9), so the bytes are
        // B'[j][t] = B[t][j] = 1, 3, 2, 4. The golden C = [[7,10],[15,22]] is unchanged.
        let b = [1.0f32, 3.0, 2.0, 4.0];

        let mut put = |base: u64, vals: &[f32]| {
            for (idx, &v) in vals.iter().enumerate() {
                let idx = idx as u64;
                match fmt {
                    NumFmt::Int4 => {
                        // Two elements per byte, low nibble first. Assert representability:
                        // silently truncating to a nibble is how an unrepresentable operand
                        // turns into a plausible wrong product.
                        let iv = v as i32;
                        assert!(
                            (-8..=7).contains(&iv),
                            "test operand {v} does not fit signed INT4"
                        );
                        let addr = base + idx / 2;
                        let cur = mem.read_le::<1>(addr).unwrap_or(0) as u8;
                        let nib = (iv as u8) & 0x0f;
                        let byte = if idx % 2 == 0 {
                            (cur & 0xf0) | nib
                        } else {
                            (cur & 0x0f) | (nib << 4)
                        };
                        mem.write_le::<1>(addr, byte as u64).unwrap();
                    }
                    NumFmt::Int | NumFmt::Sp24 => {
                        mem.write_le::<1>(base + idx, (v as i32 as u8) as u64)
                            .unwrap();
                    }
                    NumFmt::Fp8E4m3 => {
                        // 1..8 are exactly representable: E=bias+e, M=fraction.
                        let enc = f32_to_fp8(v, 4, 3, 7);
                        mem.write_le::<1>(base + idx, enc as u64).unwrap();
                    }
                    NumFmt::Fp8E5m2 => {
                        let enc = f32_to_fp8(v, 5, 2, 15);
                        mem.write_le::<1>(base + idx, enc as u64).unwrap();
                    }
                    NumFmt::Bf16 => {
                        let h = (v.to_bits() >> 16) as u16;
                        mem.write_le::<2>(base + idx * 2, h as u64).unwrap();
                    }
                    NumFmt::Fp16 => {
                        let h = f32_to_fp16(v);
                        mem.write_le::<2>(base + idx * 2, h as u64).unwrap();
                    }
                    NumFmt::Fp32 => {
                        mem.write_le::<4>(base + idx * 4, v.to_bits() as u64)
                            .unwrap();
                    }
                }
            }
        };
        put(BASE + 0x100, &a);
        put(BASE + 0x200, &b);

        let ev = AiTensorEvent {
            version: 1,
            op: 1,
            m: 2,
            n: 2,
            k: 2,
            ld_ab: 2 | (2 << 16),
            ptr_a: BASE + 0x100,
            ptr_b: BASE + 0x200,
            ptr_c: BASE + 0x300,
            flags: (fmt as u32) << 20,
            ..Default::default()
        };
        (mem, ev)
    }

    /// Encode a small positive power-scaled value into an IEEE-shaped mini float.
    ///
    /// Only used for the 1..8 test operands, which are all exactly representable in every
    /// format under test, so no rounding policy is needed or implied.
    fn f32_to_fp8(v: f32, exp_bits: u32, man_bits: u32, bias: i32) -> u8 {
        let bits = v.to_bits();
        let sign = (bits >> 31) & 1;
        let exp = ((bits >> 23) & 0xff) as i32 - 127;
        let man = bits & 0x007f_ffff;
        let shifted = man >> (23 - man_bits);
        assert_eq!(
            man,
            shifted << (23 - man_bits),
            "test operand {v} is not exact in this format"
        );
        let e = (exp + bias) as u32;
        assert!(e < (1 << exp_bits), "test operand {v} overflows exponent");
        ((sign << (exp_bits + man_bits)) | (e << man_bits) | shifted) as u8
    }

    fn f32_to_fp16(v: f32) -> u16 {
        let bits = v.to_bits();
        let sign = (bits >> 31) & 1;
        let exp = ((bits >> 23) & 0xff) as i32 - 127;
        let man = bits & 0x007f_ffff;
        let shifted = man >> 13;
        assert_eq!(man, shifted << 13, "test operand {v} is not exact in fp16");
        let e = (exp + 15) as u32;
        ((sign << 15) | (e << 10) | shifted) as u16
    }

    /// Every granted format must produce the same golden from the same matrix.
    ///
    /// This is the core claim of format support: the arithmetic differs in *encoding*, not in
    /// result, for operands all formats represent exactly. A format that decoded its operands
    /// wrongly would land here rather than in a format-specific test with a bespoke golden.
    #[test]
    fn every_format_computes_the_same_golden() {
        let want = [7i32, 10, 15, 22];
        for fmt in [
            NumFmt::Int,
            NumFmt::Int4,
            NumFmt::Fp8E4m3,
            NumFmt::Fp8E5m2,
            NumFmt::Fp16,
            NumFmt::Bf16,
            NumFmt::Fp32,
        ] {
            let (mem, ev) = fixture_fmt(fmt);
            let m = model_granting(all_formats_granted());
            let r = plan(&mem, &ev, &m)
                .unwrap_or_else(|e| panic!("{} must be accepted: {:?}", fmt.as_str(), e));
            assert_eq!(r.status, 0, "{} status", fmt.as_str());
            let got: Vec<i32> = r.c_writes.iter().map(|(_, v)| *v).collect();
            if fmt.is_float() {
                let got_f: Vec<f32> = got.iter().map(|&w| f32::from_bits(w as u32)).collect();
                let want_f: Vec<f32> = want.iter().map(|&v| v as f32).collect();
                assert_eq!(got_f, want_f, "{} C (as f32)", fmt.as_str());
            } else {
                assert_eq!(got, want, "{} C (as i32)", fmt.as_str());
            }
        }
    }

    /// An INT4 row is half the bytes of an INT8 row, so the second row must not be read from
    /// where INT8 would put it. A stride bug shows up as a wrong C rather than a fault.
    #[test]
    fn int4_rows_stride_by_packed_bytes() {
        let (mem, ev) = fixture_fmt(NumFmt::Int4);
        // A occupies 2 rows x 2 elements = 2 bytes total when packed, not 4.
        assert_eq!(row_bytes(NumFmt::Int4, 2), 1);
        let m = model_granting(all_formats_granted());
        let r = plan(&mem, &ev, &m).unwrap();
        let got: Vec<i32> = r.c_writes.iter().map(|(_, v)| *v).collect();
        assert_eq!(got, vec![7, 10, 15, 22]);
    }

    /// Each format is refused unless its own grant bit is set — one bit at a time.
    ///
    /// A mask test that only checked "nothing beyond INT8" would pass on an implementation
    /// that granted the wrong bit, so every format is checked against a mask containing
    /// exactly itself and against one containing everything else.
    #[test]
    fn a_format_is_refused_unless_its_own_grant_bit_is_set() {
        for fmt in [
            NumFmt::Int4,
            NumFmt::Fp8E4m3,
            NumFmt::Fp8E5m2,
            NumFmt::Fp16,
            NumFmt::Bf16,
            NumFmt::Fp32,
        ] {
            let (mem, ev) = fixture_fmt(fmt);
            let bit = 1u32 << fmt.grant_bit();

            // Granted alone (plus INT8, which is always granted): accepted.
            let m = model_granting(1 | bit);
            assert!(
                plan(&mem, &ev, &m).is_ok(),
                "{} must be accepted when its bit is set",
                fmt.as_str()
            );

            // Everything else granted but not this one: refused with ST_BAD_FMT.
            let m = model_granting(all_formats_granted() & !bit);
            let (why, st) = plan(&mem, &ev, &m)
                .err()
                .unwrap_or_else(|| panic!("{} must be refused", fmt.as_str()));
            assert_eq!(why, AiJobReject::UngrantedDtype, "{}", fmt.as_str());
            assert_eq!(
                st,
                8,
                "{} must report ST_BAD_FMT, not a generic error",
                fmt.as_str()
            );
        }
    }

    /// The 3-bit field cannot encode a reserved value, so every descriptor names a real
    /// format — and bits above the field must not leak into the decode.
    ///
    /// `NumFmt::from_abi` still rejects >= 8 as defence in depth for a package that widens
    /// the field, but that path is unreachable from a descriptor today. Asserting the
    /// unreachability is the useful test: it is what lets the refusal logic rely on "resolved
    /// but ungranted" being the only failure mode a guest can provoke.
    #[test]
    fn the_numfmt_field_cannot_encode_a_reserved_value() {
        for raw in 0..8u32 {
            assert!(
                NumFmt::from_abi(raw).is_some(),
                "every 3-bit value must name a format; {raw} does not"
            );
        }
        // Bits above flags[22:20] must be masked off, not folded into the format.
        let (mem, mut ev) = fixture_fmt(NumFmt::Int);
        ev.flags = 1 << 23; // just above the field
        let m = model_granting(1); // INT8 only
        let r = plan(&mem, &ev, &m).expect("a bit above the field must not change the format");
        let got: Vec<i32> = r.c_writes.iter().map(|(_, v)| *v).collect();
        assert_eq!(got, vec![7, 10, 15, 22], "must still decode as INT8");
    }

    /// An ungranted format is refused with the design's own `ST_BAD_FMT`, not a generic error.
    #[test]
    fn an_ungranted_format_reports_the_designs_bad_fmt_status() {
        let (mem, ev) = fixture_fmt(NumFmt::Fp32);
        let m = model_granting(1); // INT8 only, so FP32 is ungranted
        let (why, st) = plan(&mem, &ev, &m).expect_err("must be refused");
        assert_eq!(why, AiJobReject::UngrantedDtype);
        assert_eq!(st, 8, "ST_BAD_FMT, so a guest can pick a fallback");
    }

    /// With the field unpublished the request cannot be characterised, so the only honest
    /// reading is the all-zero legacy one — integer — and INT8 work must still succeed.
    ///
    /// This is what keeps a package that predates `numfmt` working unchanged.
    #[test]
    fn an_unpublished_numfmt_field_falls_back_to_integer() {
        let (mem, mut ev) = fixture_fmt(NumFmt::Int);
        // Set a float format in the flags, but publish no layout at all.
        ev.flags = (NumFmt::Bf16 as u32) << 20;
        let mut m = model(256);
        m.desc_layout.flags_layout = None;
        let r = plan(&mem, &ev, &m).expect("integer work must still run");
        let got: Vec<i32> = r.c_writes.iter().map(|(_, v)| *v).collect();
        assert_eq!(got, vec![7, 10, 15, 22], "must decode as INT8, not BF16");
    }

    #[test]
    fn gemm_computes_the_int8_golden() {
        let (mem, ev) = fixture();
        let m = model(256);
        let r = plan(&mem, &ev, &m).expect("descriptor must be accepted");
        assert_eq!(r.status, 0);
        assert!(!r.skipped);
        let vals: Vec<i32> = r.c_writes.iter().map(|(_, v)| *v).collect();
        assert_eq!(vals, vec![19, 22, 43, 50]);
        // C rows are contiguous: ldc = n, four bytes per element.
        let addrs: Vec<u64> = r.c_writes.iter().map(|(a, _)| *a).collect();
        assert_eq!(
            addrs,
            vec![BASE + 0x300, BASE + 0x304, BASE + 0x308, BASE + 0x30c]
        );
    }

    #[test]
    fn negative_operands_use_signed_int8() {
        let mut mem = PhysMem::new();
        mem.add(Region::new(BASE, 0x1000));
        // A = [-1], B = [2]  =>  C = -2. An unsigned read would give 510.
        mem.write_le::<1>(BASE + 0x100, (-1i8) as u8 as u64)
            .unwrap();
        mem.write_le::<1>(BASE + 0x200, 2u64).unwrap();
        let ev = AiTensorEvent {
            version: 1,
            op: 1,
            m: 1,
            n: 1,
            k: 1,
            ld_ab: 1 | (1 << 16),
            ptr_a: BASE + 0x100,
            ptr_b: BASE + 0x200,
            ptr_c: BASE + 0x300,
            ..Default::default()
        };
        let r = plan(&mem, &ev, &model(256)).unwrap();
        assert_eq!(r.c_writes, vec![(BASE + 0x300, -2)]);
    }

    #[test]
    fn a_dimension_beyond_the_accumulator_tile_is_refused() {
        let (mem, mut ev) = fixture();
        ev.k = 300;
        let (why, status) = plan(&mem, &ev, &model(256)).unwrap_err();
        assert_eq!(why, AiJobReject::BadShape);
        assert_eq!(status, 1, "ST_ERR from the ingested table");
    }

    #[test]
    fn the_tile_bound_comes_from_the_model_not_from_a_literal() {
        let (mem, mut ev) = fixture();
        ev.m = 4;
        ev.n = 1;
        ev.k = 1;
        ev.ld_ab = 1 | (1 << 16);
        // A part whose tile is 8 accepts m = 4 ...
        assert!(plan(&mem, &ev, &model(8)).is_ok());
        // ... and the same descriptor on a tile-2 part is refused.
        assert_eq!(
            plan(&mem, &ev, &model(2)).unwrap_err().0,
            AiJobReject::BadShape
        );
    }

    #[test]
    fn a_leading_dimension_smaller_than_its_extent_is_refused() {
        let (mem, mut ev) = fixture();
        ev.ld_ab = 1 | (2 << 16); // lda = 1 but k = 2
        assert_eq!(
            plan(&mem, &ev, &model(256)).unwrap_err().0,
            AiJobReject::BadShape
        );
    }

    #[test]
    fn a_zero_dimension_is_refused() {
        let (mem, mut ev) = fixture();
        ev.n = 0;
        assert_eq!(
            plan(&mem, &ev, &model(256)).unwrap_err().0,
            AiJobReject::BadShape
        );
    }

    #[test]
    fn an_unnamed_op_is_bad_op_and_a_named_one_we_do_not_run_is_skipped() {
        let (mem, mut ev) = fixture();
        ev.op = 0x4242;
        let (why, status) = plan(&mem, &ev, &model(256)).unwrap_err();
        assert_eq!(why, AiJobReject::BadOp);
        assert_eq!(status, 3);

        // OP_LAYOUT is named but not executed here: accepted, no memory touched.
        ev.op = 3;
        let r = plan(&mem, &ev, &model(256)).unwrap();
        assert!(r.skipped);
        assert!(r.c_writes.is_empty());
        assert_eq!(r.status, 0);
    }

    #[test]
    fn a_wrong_version_is_refused_with_the_packages_own_code() {
        let (mem, mut ev) = fixture();
        ev.version = 7;
        let (why, status) = plan(&mem, &ev, &model(256)).unwrap_err();
        assert_eq!(why, AiJobReject::BadVersion);
        assert_eq!(status, 2);
    }

    #[test]
    fn an_operand_outside_the_memory_map_does_not_read_as_zero() {
        let (mem, mut ev) = fixture();
        ev.ptr_a = 0xdead_0000;
        assert!(
            plan(&mem, &ev, &model(256)).is_err(),
            "an unmapped operand must fail the job, not produce a plausible C"
        );
    }

    #[test]
    fn a_sub_byte_request_is_refused_while_the_part_grants_only_dense_8_bit() {
        use g6q_core::model::{DescFlagsLayout, FlagField};
        let (mem, mut ev) = fixture();
        let mut m = model(256);
        m.desc_layout.flags_layout = Some(DescFlagsLayout {
            dtype_shift: 8,
            dtype_mask: 0x3,
            priority_shift: 16,
            priority_mask: 0xf,
            irq_bit: 2,
            dtype_combined: false,
            accmode: Some(FlagField {
                shift: 10,
                mask: 0x3,
            }),
            ew: Some(FlagField {
                shift: 12,
                mask: 0x3,
            }),
            sp24_bit: Some(14),
            numfmt: Some(FlagField {
                shift: 20,
                mask: 0x7,
            }),
        });
        // ew = 01 (INT4) with DtypeMask granting only bit 0.
        ev.flags = 1 << 12;
        let (why, _) = plan(&mem, &ev, &m).unwrap_err();
        assert_eq!(why, AiJobReject::UngrantedDtype);

        // The same descriptor with ew = 0 runs.
        ev.flags = 0;
        assert!(plan(&mem, &ev, &m).is_ok());
    }

    #[test]
    fn a_combined_flags_comment_makes_no_arithmetic_mode_claim() {
        use g6q_core::model::DescFlagsLayout;
        let (mem, mut ev) = fixture();
        let mut m = model(256);
        m.desc_layout.flags_layout = Some(DescFlagsLayout {
            dtype_shift: 8,
            dtype_mask: 0x3f,
            dtype_combined: true,
            ..Default::default()
        });
        ev.flags = 0x3f << 8;
        assert!(
            plan(&mem, &ev, &m).is_ok(),
            "an unresolved packing must not be read as a mode request"
        );
    }
}
