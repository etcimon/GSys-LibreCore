// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! IR ops → `Desc64` (no device I/O).
//! Enforces AccTile limits; optional host-side tiling for larger GEMMs.

use ai_tensor_abi::{AccTile, CapRegs, Desc64, NumFmt, FLAG_IRQ, OP_GEMM};
use thiserror::Error;

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum IrError {
    #[error("unsupported dtype for island path: {0}")]
    UnsupportedDtype(&'static str),
    #[error("shape mismatch or zero dimension")]
    BadShape,
    #[error("dims m={m} n={n} k={k} exceed AccTile {tm}x{tn}x{tk}")]
    ExceedsTile {
        m: u32,
        n: u32,
        k: u32,
        tm: u32,
        tn: u32,
        tk: u32,
    },
    /// The island does not grant the requested numeric format.
    ///
    /// Carries the granted mask so a caller can pick a fallback it knows will be accepted,
    /// rather than probing formats one descriptor at a time.
    #[error("island does not grant {requested:?} (granted mask {granted:#06x})")]
    UngrantedDtype { requested: NumFmt, granted: u16 },
}

/// Operand element type for a lowered GEMM.
///
/// These are framework-facing names; each maps to exactly one `NumFmt` ABI value, and
/// lowering refuses any the island does not grant. The mapping is one-to-one and total on
/// purpose — a framework dtype with no ABI encoding must fail to lower rather than be
/// silently approximated by a nearby format.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DType {
    /// INT8 operands, INT32 accumulator. The frozen baseline every golden is written in.
    S8,
    /// INT4 operands packed two per byte, INT32 accumulator.
    S4,
    /// 8-bit float, 4-bit exponent (OCP E4M3); FP32 accumulator.
    Fp8E4m3,
    /// 8-bit float, 5-bit exponent (OCP E5M2); FP32 accumulator.
    Fp8E5m2,
    /// IEEE 754 binary16; FP32 accumulator.
    Fp16,
    /// bfloat16; FP32 accumulator.
    Bf16,
    /// IEEE 754 binary32; FP32 accumulator.
    Fp32,
}

impl DType {
    /// The ABI numeric format this element type lowers to.
    pub fn numfmt(self) -> NumFmt {
        match self {
            DType::S8 => NumFmt::Int,
            DType::S4 => NumFmt::Int4,
            DType::Fp8E4m3 => NumFmt::Fp8E4m3,
            DType::Fp8E5m2 => NumFmt::Fp8E5m2,
            DType::Fp16 => NumFmt::Fp16,
            DType::Bf16 => NumFmt::Bf16,
            DType::Fp32 => NumFmt::Fp32,
        }
    }

    /// Stable wire name.
    pub fn as_str(self) -> &'static str {
        self.numfmt().as_str()
    }

    /// Bytes spanned by `n` consecutive elements, accounting for INT4 packing.
    pub fn row_bytes(self, n: u32) -> u32 {
        self.numfmt().row_bytes(n)
    }

    /// True when `C` holds IEEE binary32 bits rather than a two's-complement `i32`.
    ///
    /// `C` is 32 bits wide in the ABI either way, so the difference is interpretation. The
    /// caller knows which because it chose the dtype.
    pub fn c_is_float(self) -> bool {
        !matches!(self, DType::S8 | DType::S4)
    }
}

#[derive(Debug, Clone)]
pub struct Gemm {
    pub m: u32,
    pub n: u32,
    pub k: u32,
    pub dtype: DType,
    pub ptr_a: u64,
    pub ptr_b: u64,
    pub ptr_c: u64,
    pub ptr_done: u64,
    pub irq: bool,
}

impl Gemm {
    /// Lower to a single Desc64. Fails if dims exceed `tile` (default island_p3 256).
    pub fn lower(&self) -> Result<Desc64, IrError> {
        self.lower_with_tile(AccTile::ISLAND_P3_DEFAULT)
    }

    pub fn lower_with_tile(&self, tile: AccTile) -> Result<Desc64, IrError> {
        if self.m == 0 || self.n == 0 || self.k == 0 {
            return Err(IrError::BadShape);
        }
        if !tile.fits(self.m, self.n, self.k) {
            return Err(IrError::ExceedsTile {
                m: self.m,
                n: self.n,
                k: self.k,
                tm: tile.m,
                tn: tile.n,
                tk: tile.k,
            });
        }
        let mut d = Desc64::gemm(self.m, self.n, self.k);
        d.op = OP_GEMM;
        d.ld_ab = self.k | (self.n << 16);
        d.ptr_a = self.ptr_a;
        d.ptr_b = self.ptr_b;
        d.ptr_c = self.ptr_c;
        d.ptr_done = self.ptr_done;
        if self.irq {
            d.flags |= FLAG_IRQ;
        }
        // Carry the element type in the descriptor. It travels with the work rather than
        // living in a CSR because a descriptor outlives the thread that enqueued it and may
        // arrive from a host process across the PCIe transport, which has no CSR at all.
        d.flags = self.dtype.numfmt().into_flags(d.flags);
        Ok(d)
    }

    /// Lower, but refuse a dtype the island's capability window does not grant.
    ///
    /// Separate from [`Self::lower_with_tile`] rather than folded into it: lowering is a pure
    /// encoding step usable offline against fixtures, whereas this needs discovered caps. A
    /// runtime with caps in hand should always prefer this one — submitting an ungranted
    /// format costs a descriptor round trip to learn `ST_BAD_FMT`, and the point of publishing
    /// a grant mask is to make that answerable locally.
    pub fn lower_checked(&self, tile: AccTile, caps: &CapRegs) -> Result<Desc64, IrError> {
        let fmt = self.dtype.numfmt();
        if !caps.grants(fmt) {
            return Err(IrError::UngrantedDtype {
                requested: fmt,
                granted: caps.dtype_mask,
            });
        }
        self.lower_with_tile(tile)
    }
}

/// One tile of a blocked GEMM (host-side; island runs one AccTile at a time).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GemmTile {
    pub i0: u32,
    pub j0: u32,
    pub t0: u32,
    pub tm: u32,
    pub tn: u32,
    pub tk: u32,
}

/// Iterate AccTile-sized blocks over a large GEMM (row-major A/B/C).
/// Caller adjusts pointers by element offsets: A += i0*lda + t0, etc.
pub fn tile_gemm(m: u32, n: u32, k: u32, tile: AccTile) -> Vec<GemmTile> {
    let mut out = Vec::new();
    if m == 0 || n == 0 || k == 0 {
        return out;
    }
    let mut i = 0u32;
    while i < m {
        let tm = (m - i).min(tile.m);
        let mut j = 0u32;
        while j < n {
            let tn = (n - j).min(tile.n);
            let mut t = 0u32;
            while t < k {
                let tk = (k - t).min(tile.k);
                out.push(GemmTile {
                    i0: i,
                    j0: j,
                    t0: t,
                    tm,
                    tn,
                    tk,
                });
                t += tk;
            }
            j += tn;
        }
        i += tm;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gemm_of(dtype: DType) -> Gemm {
        Gemm {
            m: 4,
            n: 4,
            k: 4,
            dtype,
            ptr_a: 0x1000,
            ptr_b: 0x2000,
            ptr_c: 0x3000,
            ptr_done: 0x4000,
            irq: false,
        }
    }

    /// Every dtype must land in `flags[22:20]` as its own ABI value, and nowhere else.
    ///
    /// Checked against `NumFmt::from_flags` rather than a literal so the test cannot drift
    /// from the shift the ABI publishes.
    #[test]
    fn every_dtype_lowers_to_its_own_numfmt() {
        for dtype in [
            DType::S8,
            DType::S4,
            DType::Fp8E4m3,
            DType::Fp8E5m2,
            DType::Fp16,
            DType::Bf16,
            DType::Fp32,
        ] {
            let d = gemm_of(dtype).lower().unwrap();
            assert_eq!(
                NumFmt::from_flags(d.flags),
                Some(dtype.numfmt()),
                "{} must round-trip through flags",
                dtype.as_str()
            );
        }
    }

    /// S8 must still lower to an all-zero `numfmt`, or every descriptor built before the
    /// field existed changes meaning and ContractVersion=1 stops being true.
    #[test]
    fn s8_still_lowers_to_the_all_zero_encoding() {
        let d = gemm_of(DType::S8).lower().unwrap();
        assert_eq!(
            (d.flags >> ai_tensor_abi::FLAG_NUMFMT_SHIFT) & ai_tensor_abi::FLAG_NUMFMT_MASK,
            0
        );
    }

    /// `numfmt` must not disturb the IRQ bit, which shares the same word.
    #[test]
    fn numfmt_does_not_clobber_the_irq_flag() {
        let mut g = gemm_of(DType::Bf16);
        g.irq = true;
        let d = g.lower().unwrap();
        assert!(d.irq(), "IRQ must survive the numfmt write");
        assert_eq!(NumFmt::from_flags(d.flags), Some(NumFmt::Bf16));
    }

    /// `lower_checked` refuses a dtype the capability window does not grant.
    ///
    /// The live island grants dense INT8 only, so this is the path a framework actually hits
    /// today when a model arrives in bfloat16.
    #[test]
    fn an_ungranted_dtype_is_refused_against_the_live_grant_mask() {
        let caps = CapRegs::island_p3_sim_default();
        assert_eq!(caps.dtype_mask, 0x0001, "live island is dense INT8 only");

        // INT8 is granted.
        assert!(gemm_of(DType::S8)
            .lower_checked(AccTile::ISLAND_P3_DEFAULT, &caps)
            .is_ok());

        // Everything else is not, and the error names what was asked for.
        for dtype in [
            DType::S4,
            DType::Fp8E4m3,
            DType::Fp8E5m2,
            DType::Fp16,
            DType::Bf16,
            DType::Fp32,
        ] {
            let err = gemm_of(dtype)
                .lower_checked(AccTile::ISLAND_P3_DEFAULT, &caps)
                .expect_err("must be refused");
            assert_eq!(
                err,
                IrError::UngrantedDtype {
                    requested: dtype.numfmt(),
                    granted: 0x0001,
                },
                "{}",
                dtype.as_str()
            );
        }
    }

    /// A SKU granting more accepts more, without any change to the lowering itself.
    #[test]
    fn a_wider_grant_mask_accepts_the_float_formats() {
        let mut caps = CapRegs::island_p3_sim_default();
        caps.dtype_mask = 0x00ff;
        for dtype in [DType::Bf16, DType::Fp16, DType::Fp32, DType::S4] {
            assert!(
                gemm_of(dtype)
                    .lower_checked(AccTile::ISLAND_P3_DEFAULT, &caps)
                    .is_ok(),
                "{} must be accepted when granted",
                dtype.as_str()
            );
        }
    }

    /// Row extents follow the packing, which is what a host tiler must stride by.
    #[test]
    fn row_bytes_follow_the_element_width() {
        assert_eq!(DType::S8.row_bytes(8), 8);
        assert_eq!(DType::S4.row_bytes(8), 4, "two elements per byte");
        assert_eq!(DType::S4.row_bytes(7), 4, "odd length rounds up");
        assert_eq!(DType::Bf16.row_bytes(8), 16);
        assert_eq!(DType::Fp32.row_bytes(8), 32);
    }

    /// Only the integer dtypes write a two's-complement `C`.
    #[test]
    fn c_interpretation_tracks_the_dtype() {
        assert!(!DType::S8.c_is_float());
        assert!(!DType::S4.c_is_float());
        for dtype in [
            DType::Fp8E4m3,
            DType::Fp8E5m2,
            DType::Fp16,
            DType::Bf16,
            DType::Fp32,
        ] {
            assert!(dtype.c_is_float(), "{}", dtype.as_str());
        }
    }

    #[test]
    fn lower_gemm() {
        let g = Gemm {
            m: 4,
            n: 4,
            k: 4,
            dtype: DType::S8,
            ptr_a: 0x1000,
            ptr_b: 0x2000,
            ptr_c: 0x3000,
            ptr_done: 0x4000,
            irq: false,
        };
        let d = g.lower().unwrap();
        assert_eq!(d.m, 4);
        assert_eq!(d.ptr_done, 0x4000);
    }

    #[test]
    fn reject_oversize_tile() {
        let g = Gemm {
            m: 257,
            n: 1,
            k: 1,
            dtype: DType::S8,
            ptr_a: 0,
            ptr_b: 0,
            ptr_c: 0,
            ptr_done: 0,
            irq: false,
        };
        assert!(matches!(g.lower(), Err(IrError::ExceedsTile { .. })));
    }

    #[test]
    fn tile_large_512() {
        let tiles = tile_gemm(512, 512, 512, AccTile::ISLAND_P3_DEFAULT);
        // 2x2x2 = 8 tiles of 256
        assert_eq!(tiles.len(), 8);
        assert_eq!(tiles[0].tm, 256);
        assert_eq!(tiles.last().unwrap().i0, 256);
    }
}
