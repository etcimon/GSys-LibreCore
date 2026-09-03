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
    if requests_ungranted_mode(model, ev.flags) == Some(true) {
        return Err((AiJobReject::UngrantedDtype, status_of(model, ST_ERR, 1)));
    }

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
        || (ldb as u64) < n
    {
        return Err((AiJobReject::BadShape, status_of(model, ST_ERR, 1)));
    }

    // ---- compute ---------------------------------------------------------------------
    //   C[i,j] (i32) = sum_t A[i,t] * B[t,j],  A/B int8 row-major
    //   A strides by `lda`, B by `ldb`; C rows are contiguous, so `ldc = n`.
    // A read the guest memory map cannot satisfy is an error, not a zero: silently
    // reading zero would produce a wrong C that still looks like a successful job.
    let mut c_writes = Vec::with_capacity((m * n) as usize);
    for i in 0..m {
        let a_row = ev.ptr_a.wrapping_add(i.wrapping_mul(lda as u64));
        for j in 0..n {
            let mut acc: i32 = 0;
            for t in 0..k {
                let a = match mem.read_le::<1>(a_row.wrapping_add(t)) {
                    Ok(v) => v as u8 as i8 as i32,
                    Err(_) => return Err((AiJobReject::BadShape, status_of(model, ST_ERR, 1))),
                };
                let b_addr = ev
                    .ptr_b
                    .wrapping_add(t.wrapping_mul(ldb as u64))
                    .wrapping_add(j);
                let b = match mem.read_le::<1>(b_addr) {
                    Ok(v) => v as u8 as i8 as i32,
                    Err(_) => return Err((AiJobReject::BadShape, status_of(model, ST_ERR, 1))),
                };
                acc = acc.wrapping_add(a.wrapping_mul(b));
            }
            let c_addr = ev
                .ptr_c
                .wrapping_add(i.wrapping_mul(n).wrapping_add(j).wrapping_mul(4));
            c_writes.push((c_addr, acc));
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
        l
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
        // A = [[1, 2], [3, 4]] at +0x100, lda = 2
        // B = [[5, 6], [7, 8]] at +0x200, ldb = 2
        // C = A*B = [[19, 22], [43, 50]] at +0x300
        for (off, v) in [(0u64, 1i8), (1, 2), (2, 3), (3, 4)] {
            mem.write_le::<1>(BASE + 0x100 + off, v as u8 as u64)
                .unwrap();
        }
        for (off, v) in [(0u64, 5i8), (1, 6), (2, 7), (3, 8)] {
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
