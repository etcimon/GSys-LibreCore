// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Numeric formats for the emulated AI island: INT8, INT4, FP8 (E4M3/E5M2), FP16, BF16, FP32.
//!
//! # Why this exists separately from `gemm`
//!
//! `gemm` owns the descriptor contract — version, op, shape, grant. This module owns only
//! *arithmetic*: how many operand bytes a format occupies, how to decode one element, and
//! how products accumulate. Keeping them apart matters because the two have different
//! authorities. The contract is ingested from the design and may not be second-guessed; the
//! arithmetic is defined by IEEE 754 and OCP FP8, and is the same wherever it runs.
//!
//! # The values are the design's, the encodings are not
//!
//! Format *selection* comes from `config_pkg::AI_FMT_*` through the descriptor's `numfmt`
//! field and the capability window's grant mask — both ingested. What is written here is
//! only how the bits of an already-selected format decode, which no package publishes and
//! which is fixed by external standard:
//!
//! | Format | Bits | Exponent | Mantissa | Bias | Standard |
//! |---|---|---|---|---|---|
//! | FP32 | 32 | 8 | 23 | 127 | IEEE 754 binary32 |
//! | FP16 | 16 | 5 | 10 | 15 | IEEE 754 binary16 |
//! | BF16 | 16 | 8 | 7 | 127 | truncated binary32 |
//! | FP8 E4M3 | 8 | 4 | 3 | 7 | OCP 8-bit FP |
//! | FP8 E5M2 | 8 | 5 | 2 | 15 | OCP 8-bit FP |
//! | INT8 | 8 | — | — | — | two's complement |
//! | INT4 | 4 | — | — | — | two's complement, two per byte |
//!
//! # Accumulator choice, and why it is not configurable here
//!
//! Integer formats accumulate in `i32`; float formats accumulate in `f32`. That mirrors the
//! only accumulator the descriptor ABI can describe — `C` is 32-bit and `ldc = n` — so a
//! wider accumulator would produce results the guest cannot read back. `f64` accumulation
//! would also make the model *more* accurate than the hardware it stands in for, which is
//! the wrong direction for a reference: a golden that the RTL cannot reproduce is not a
//! golden. Products are formed in `f32` and summed in `f32`, in the `k` order the engine
//! walks, so the model is reproducible rather than merely close.

/// A numeric format, indexed exactly as `config_pkg::AI_FMT_*`.
///
/// The discriminants are the ABI values, not an internal numbering: the grant mask is a
/// bitmap over these same indices, so a grant check is `mask >> fmt & 1` rather than a
/// translation table that can disagree with itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NumFmt {
    /// Integer; element width comes from `ew`, signedness from `dtype`.
    Int = 0,
    /// 4-bit signed integer, two elements per byte.
    Int4 = 1,
    /// Structured 2:4 sparsity on operand A. A sparsity mode, not an element encoding.
    Sp24 = 2,
    /// 8-bit float, 4-bit exponent, 3-bit mantissa (OCP).
    Fp8E4m3 = 3,
    /// 8-bit float, 5-bit exponent, 2-bit mantissa (OCP).
    Fp8E5m2 = 4,
    /// IEEE 754 binary16.
    Fp16 = 5,
    /// bfloat16.
    Bf16 = 6,
    /// IEEE 754 binary32.
    Fp32 = 7,
}

impl NumFmt {
    /// Decode the descriptor's `numfmt` value.
    ///
    /// Returns `None` for a value the ABI reserves. Reserved is refused rather than mapped
    /// to a default: a part that silently treated an unknown format as INT8 would return
    /// plausible wrong numbers, which is the failure this whole field exists to prevent.
    pub fn from_abi(v: u32) -> Option<Self> {
        Some(match v {
            0 => NumFmt::Int,
            1 => NumFmt::Int4,
            2 => NumFmt::Sp24,
            3 => NumFmt::Fp8E4m3,
            4 => NumFmt::Fp8E5m2,
            5 => NumFmt::Fp16,
            6 => NumFmt::Bf16,
            7 => NumFmt::Fp32,
            _ => return None,
        })
    }

    /// Grant-mask bit index for this format.
    pub fn grant_bit(self) -> u32 {
        self as u32
    }

    /// Status a descriptor of this format receives.
    ///
    /// `0` is `ST_OK`. `8` is `ST_BAD_FMT`. The mask bit is necessary.
    /// Float codes also need `fp_datapath`: the synthesizable integer strip
    /// passes `false` and refuses them. Structured 2:4 is refused either way.
    pub fn status_for_mask(self, mask: u32, fp_datapath: bool) -> u16 {
        let float = self.is_float();
        if self == NumFmt::Sp24 || (mask & (1u32 << self.grant_bit())) == 0 || (float && !fp_datapath)
        {
            8
        } else {
            0
        }
    }

    /// Stable wire name, for traces, artifacts and reports.
    pub fn as_str(self) -> &'static str {
        match self {
            NumFmt::Int => "int",
            NumFmt::Int4 => "int4",
            NumFmt::Sp24 => "sp24",
            NumFmt::Fp8E4m3 => "fp8e4m3",
            NumFmt::Fp8E5m2 => "fp8e5m2",
            NumFmt::Fp16 => "fp16",
            NumFmt::Bf16 => "bf16",
            NumFmt::Fp32 => "fp32",
        }
    }

    /// True when products accumulate in `f32` rather than `i32`.
    pub fn is_float(self) -> bool {
        matches!(
            self,
            NumFmt::Fp8E4m3 | NumFmt::Fp8E5m2 | NumFmt::Fp16 | NumFmt::Bf16 | NumFmt::Fp32
        )
    }

    /// Storage bytes per element, or `None` for sub-byte formats that share a byte.
    ///
    /// `Sp24` returns the INT8 width because it is a sparsity mode layered on an element
    /// encoding, not an encoding itself.
    pub fn elem_bytes(self) -> Option<u64> {
        Some(match self {
            NumFmt::Int | NumFmt::Sp24 | NumFmt::Fp8E4m3 | NumFmt::Fp8E5m2 => 1,
            NumFmt::Fp16 | NumFmt::Bf16 => 2,
            NumFmt::Fp32 => 4,
            NumFmt::Int4 => return None,
        })
    }

    /// Elements packed into one byte. 2 for INT4, 1 otherwise.
    pub fn elems_per_byte(self) -> u64 {
        match self {
            NumFmt::Int4 => 2,
            _ => 1,
        }
    }

    /// Effective MAC-rate multiplier relative to dense INT8, for **modelled** reporting.
    ///
    /// This is a *model*, and it is only ever legitimate to report it as one. The ratios
    /// follow from operand width against a fixed multiplier array and a fixed operand
    /// bandwidth, which is the same reasoning `scaling-100tops.md` §1 uses for INT4:
    ///
    /// | Format | ×INT8 | Reasoning |
    /// |---|---|---|
    /// | INT8, FP8 | 1 | one byte per operand, one lane each |
    /// | INT4 | 2 | two elements per operand byte |
    /// | FP16, BF16 | 1/2 | two bytes per operand |
    /// | FP32 | 1/4 | four bytes per operand |
    ///
    /// Returned as a rational so the caller never sees a rounded 0. **No backend may quote
    /// these as throughput**: the emulator has no cycles, and even on hardware the FP ratios
    /// depend on whether the array natively multiplies those widths or decomposes them. The
    /// headline dense-INT8 figure stays separate for exactly that reason.
    pub fn mac_rate_ratio(self) -> (u32, u32) {
        match self {
            NumFmt::Int | NumFmt::Sp24 | NumFmt::Fp8E4m3 | NumFmt::Fp8E5m2 => (1, 1),
            NumFmt::Int4 => (2, 1),
            NumFmt::Fp16 | NumFmt::Bf16 => (1, 2),
            NumFmt::Fp32 => (1, 4),
        }
    }
}

/// Sign-extend the low `bits` of `v`.
fn sext(v: u32, bits: u32) -> i32 {
    let sh = 32 - bits;
    ((v << sh) as i32) >> sh
}

/// Widen an FP8 E4M3 byte to `f32` (OCP: 4-bit exponent, 3-bit mantissa, bias 7).
///
/// E4M3 has no infinities; `S.1111.111` is the only NaN. Handled explicitly because mapping
/// it onto a normal value would let a NaN operand silently produce a finite product.
pub fn fp8_e4m3_to_f32(b: u8) -> f32 {
    decode_float(b as u32, 4, 3, 7, /* has_inf */ false)
}

/// Widen an FP8 E5M2 byte to `f32` (OCP: 5-bit exponent, 2-bit mantissa, bias 15).
///
/// E5M2 does have infinities and NaNs, in the IEEE pattern.
pub fn fp8_e5m2_to_f32(b: u8) -> f32 {
    decode_float(b as u32, 5, 2, 15, /* has_inf */ true)
}

/// Widen an IEEE binary16 half to `f32`.
pub fn fp16_to_f32(h: u16) -> f32 {
    decode_float(h as u32, 5, 10, 15, /* has_inf */ true)
}

/// Widen a bfloat16 to `f32`. bf16 is the top 16 bits of a binary32, so this is a shift.
pub fn bf16_to_f32(h: u16) -> f32 {
    f32::from_bits((h as u32) << 16)
}

/// Decode a small IEEE-shaped float into `f32`.
///
/// Written once and shared rather than unrolled per format: subnormals and the all-ones
/// exponent are where hand-written per-format converters go wrong, and a single path means
/// one place to be correct. `has_inf` distinguishes IEEE-shaped types from FP8 E4M3, whose
/// maximum exponent still encodes finite values.
fn decode_float(bits: u32, exp_bits: u32, man_bits: u32, bias: i32, has_inf: bool) -> f32 {
    let man_mask = (1u32 << man_bits) - 1;
    let exp_mask = (1u32 << exp_bits) - 1;
    let sign = if (bits >> (exp_bits + man_bits)) & 1 == 1 {
        -1.0f32
    } else {
        1.0f32
    };
    let exp = ((bits >> man_bits) & exp_mask) as i32;
    let man = bits & man_mask;

    if exp == exp_mask as i32 {
        if has_inf {
            return if man == 0 {
                sign * f32::INFINITY
            } else {
                f32::NAN
            };
        }
        // E4M3: the top exponent is finite except for the all-ones mantissa.
        if man == man_mask {
            return f32::NAN;
        }
    }

    let scale = (man_bits as i32) as f32;
    let _ = scale;
    if exp == 0 {
        // Subnormal: no implicit leading 1, exponent fixed at 1 - bias.
        let m = man as f32 / (1u32 << man_bits) as f32;
        sign * m * 2f32.powi(1 - bias)
    } else {
        let m = 1.0f32 + man as f32 / (1u32 << man_bits) as f32;
        sign * m * 2f32.powi(exp - bias)
    }
}

/// Narrow an `f32` accumulator to the 32-bit word the descriptor's `C` holds.
///
/// Float modes write IEEE binary32 bits; integer modes write two's-complement `i32`. `C` is
/// 32 bits wide in the ABI either way, so the distinction is in interpretation, not width,
/// and the consumer knows which because it chose the format.
pub fn pack_c(acc_f32: f32) -> i32 {
    if acc_f32.is_nan() {
        0x7fc0_0000
    } else {
        acc_f32.to_bits() as i32
    }
}

/// Read one element of `fmt` at logical index `idx` in a row starting at `base`.
///
/// `read` is the caller's guest-memory accessor, returning the byte at an address or `None`
/// when the address is unmapped. Sub-byte formats resolve the containing byte and then the
/// nibble, so INT4 needs no special case in the GEMM loop.
///
/// Returns `None` when any needed byte is unmapped. An unmapped operand is an error rather
/// than a zero: reading zero would produce a wrong `C` that still looks like a finished job.
pub fn read_elem<F>(fmt: NumFmt, base: u64, idx: u64, mut read: F) -> Option<Elem>
where
    F: FnMut(u64) -> Option<u8>,
{
    match fmt {
        NumFmt::Int4 => {
            let byte = read(base.checked_add(idx / 2)?)?;
            // Low nibble first: little-endian element order within the byte, matching how
            // the packed operand is written by the host runtime.
            let nib = if idx % 2 == 0 { byte & 0x0f } else { byte >> 4 };
            Some(Elem::Int(sext(nib as u32, 4)))
        }
        NumFmt::Int | NumFmt::Sp24 => {
            let b = read(base.checked_add(idx)?)?;
            Some(Elem::Int(b as i8 as i32))
        }
        NumFmt::Fp8E4m3 => Some(Elem::Float(fp8_e4m3_to_f32(read(base.checked_add(idx)?)?))),
        NumFmt::Fp8E5m2 => Some(Elem::Float(fp8_e5m2_to_f32(read(base.checked_add(idx)?)?))),
        NumFmt::Fp16 | NumFmt::Bf16 => {
            let a = base.checked_add(idx.checked_mul(2)?)?;
            let lo = read(a)? as u16;
            let hi = read(a.checked_add(1)?)? as u16;
            let h = lo | (hi << 8);
            Some(Elem::Float(if fmt == NumFmt::Bf16 {
                bf16_to_f32(h)
            } else {
                fp16_to_f32(h)
            }))
        }
        NumFmt::Fp32 => {
            let a = base.checked_add(idx.checked_mul(4)?)?;
            let mut w = 0u32;
            for i in 0..4 {
                w |= (read(a.checked_add(i)?)? as u32) << (8 * i);
            }
            Some(Elem::Float(f32::from_bits(w)))
        }
    }
}

/// One decoded operand element.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Elem {
    /// Integer element, already sign-extended to `i32`.
    Int(i32),
    /// Float element, widened to `f32`.
    Float(f32),
}

/// Bytes spanned by `n` consecutive elements of `fmt`.
///
/// Used to validate a leading dimension: `lda` counts *elements*, so the row extent in bytes
/// is what a packed INT4 row actually needs, which is half an INT8 row rather than the same.
pub fn row_bytes(fmt: NumFmt, n: u64) -> u64 {
    match fmt.elem_bytes() {
        Some(b) => n.saturating_mul(b),
        None => n.div_ceil(fmt.elems_per_byte()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The ABI index and the grant-mask bit must be the same number.
    ///
    /// If these ever diverge, a grant check silently tests the wrong format, which is
    /// undetectable from outside — hence a test rather than a comment.
    #[test]
    fn abi_value_equals_grant_bit() {
        for v in 0..8u32 {
            let f = NumFmt::from_abi(v).expect("0..8 are all defined");
            assert_eq!(f.grant_bit(), v, "{} must grant at bit {v}", f.as_str());
        }
    }

    /// Live mask, fast mask without a float datapath, and fast mask with one.
    /// Matches ai-tensor `FormatTrace::from_request`.
    #[test]
    fn live_and_fast_masks_agree_on_the_eight_codes() {
        const LIVE: u32 = 0x0003;
        const FAST: u32 = 0x00fb;
        for v in 0..8u32 {
            let f = NumFmt::from_abi(v).unwrap();
            let live = f.status_for_mask(LIVE, false);
            let bare = f.status_for_mask(FAST, false);
            let model = f.status_for_mask(FAST, true);
            if f == NumFmt::Sp24 {
                assert_eq!((live, bare, model), (8, 8, 8));
            } else if v <= 1 {
                assert_eq!((live, bare, model), (0, 0, 0), "{}", f.as_str());
            } else {
                assert_eq!((live, bare, model), (8, 8, 0), "{}", f.as_str());
            }
        }
    }

    #[test]
    fn reserved_formats_are_refused_not_defaulted() {
        assert_eq!(NumFmt::from_abi(8), None);
        assert_eq!(NumFmt::from_abi(0xffff_ffff), None);
    }

    /// `AI_FMT_INT` must be zero, or every pre-`numfmt` descriptor changes meaning.
    #[test]
    fn integer_is_the_all_zero_encoding() {
        assert_eq!(NumFmt::Int as u32, 0);
        assert_eq!(NumFmt::from_abi(0), Some(NumFmt::Int));
    }

    #[test]
    fn bf16_is_the_top_half_of_a_binary32() {
        // 1.0f32 == 0x3f80_0000, so bf16 1.0 == 0x3f80.
        assert_eq!(bf16_to_f32(0x3f80), 1.0);
        assert_eq!(bf16_to_f32(0xbf80), -1.0);
        assert_eq!(bf16_to_f32(0x0000), 0.0);
        // Any f32 whose low 16 bits are zero round-trips exactly.
        for v in [1.0f32, -2.5, 0.5, 256.0] {
            let b = (v.to_bits() >> 16) as u16;
            assert_eq!(bf16_to_f32(b), v, "bf16 round-trip {v}");
        }
    }

    #[test]
    fn fp16_normals_subnormals_and_specials() {
        assert_eq!(fp16_to_f32(0x3c00), 1.0);
        assert_eq!(fp16_to_f32(0xbc00), -1.0);
        assert_eq!(fp16_to_f32(0x4000), 2.0);
        assert_eq!(fp16_to_f32(0x0000), 0.0);
        // Smallest positive subnormal: 2^-24.
        assert_eq!(fp16_to_f32(0x0001), 2f32.powi(-24));
        // Largest normal: 65504.
        assert_eq!(fp16_to_f32(0x7bff), 65504.0);
        assert!(fp16_to_f32(0x7c00).is_infinite());
        assert!(fp16_to_f32(0x7e00).is_nan());
    }

    /// E4M3 has no infinity: the top exponent is finite except for the all-ones mantissa.
    ///
    /// Getting this wrong is the classic FP8 bug — it turns 448.0, the format's largest
    /// finite value, into an infinity and poisons the whole accumulator.
    #[test]
    fn fp8_e4m3_has_no_infinity() {
        assert_eq!(fp8_e4m3_to_f32(0x38), 1.0);
        assert_eq!(fp8_e4m3_to_f32(0xb8), -1.0);
        assert_eq!(fp8_e4m3_to_f32(0x00), 0.0);
        // 0x7e = S=0 E=1111 M=110 -> finite 448.0, NOT infinity.
        assert_eq!(fp8_e4m3_to_f32(0x7e), 448.0);
        assert!(fp8_e4m3_to_f32(0x7e).is_finite());
        // Only the all-ones mantissa is NaN.
        assert!(fp8_e4m3_to_f32(0x7f).is_nan());
        // Smallest positive subnormal: 2^-9.
        assert_eq!(fp8_e4m3_to_f32(0x01), 2f32.powi(-9));
    }

    /// E5M2 is IEEE-shaped and does have infinity, unlike E4M3.
    #[test]
    fn fp8_e5m2_is_ieee_shaped() {
        assert_eq!(fp8_e5m2_to_f32(0x3c), 1.0);
        assert_eq!(fp8_e5m2_to_f32(0xbc), -1.0);
        // Largest normal: 57344.
        assert_eq!(fp8_e5m2_to_f32(0x7b), 57344.0);
        assert!(fp8_e5m2_to_f32(0x7c).is_infinite());
        assert!(fp8_e5m2_to_f32(0x7d).is_nan());
        // Smallest positive subnormal: 2^-16.
        assert_eq!(fp8_e5m2_to_f32(0x01), 2f32.powi(-16));
    }

    #[test]
    fn int4_packs_two_elements_low_nibble_first() {
        // 0x21 -> element 0 = 1, element 1 = 2.
        let mem = [0x21u8];
        let rd = |a: u64| mem.get(a as usize).copied();
        assert_eq!(read_elem(NumFmt::Int4, 0, 0, rd), Some(Elem::Int(1)));
        assert_eq!(read_elem(NumFmt::Int4, 0, 1, rd), Some(Elem::Int(2)));
        // 0xf8 -> element 0 = -8, element 1 = -1 (both sign-extended).
        let mem = [0xf8u8];
        let rd = |a: u64| mem.get(a as usize).copied();
        assert_eq!(read_elem(NumFmt::Int4, 0, 0, rd), Some(Elem::Int(-8)));
        assert_eq!(read_elem(NumFmt::Int4, 0, 1, rd), Some(Elem::Int(-1)));
    }

    #[test]
    fn int8_sign_extends() {
        let mem = [0x7fu8, 0x80, 0xff];
        let rd = |a: u64| mem.get(a as usize).copied();
        assert_eq!(read_elem(NumFmt::Int, 0, 0, rd), Some(Elem::Int(127)));
        assert_eq!(read_elem(NumFmt::Int, 0, 1, rd), Some(Elem::Int(-128)));
        assert_eq!(read_elem(NumFmt::Int, 0, 2, rd), Some(Elem::Int(-1)));
    }

    #[test]
    fn wide_formats_read_little_endian() {
        // bf16 1.0 = 0x3f80 -> bytes 80 3f.
        let mem = [0x80u8, 0x3f];
        let rd = |a: u64| mem.get(a as usize).copied();
        assert_eq!(read_elem(NumFmt::Bf16, 0, 0, rd), Some(Elem::Float(1.0)));
        // fp32 1.0 = 0x3f800000 -> bytes 00 00 80 3f.
        let mem = [0x00u8, 0x00, 0x80, 0x3f];
        let rd = |a: u64| mem.get(a as usize).copied();
        assert_eq!(read_elem(NumFmt::Fp32, 0, 0, rd), Some(Elem::Float(1.0)));
    }

    #[test]
    fn an_unmapped_operand_byte_is_an_error_not_a_zero() {
        let rd = |_: u64| None;
        for f in [
            NumFmt::Int,
            NumFmt::Int4,
            NumFmt::Fp8E4m3,
            NumFmt::Fp16,
            NumFmt::Bf16,
            NumFmt::Fp32,
        ] {
            assert_eq!(
                read_elem(f, 0, 0, rd),
                None,
                "{} must not read 0",
                f.as_str()
            );
        }
        // A wide format whose FIRST byte is mapped but whose last is not must still fail.
        let mem = [0x00u8];
        let rd = |a: u64| mem.get(a as usize).copied();
        assert_eq!(read_elem(NumFmt::Fp32, 0, 0, rd), None);
    }

    /// A packed INT4 row occupies half the bytes of the same-length INT8 row.
    #[test]
    fn row_bytes_tracks_packing() {
        assert_eq!(row_bytes(NumFmt::Int, 8), 8);
        assert_eq!(row_bytes(NumFmt::Int4, 8), 4);
        assert_eq!(row_bytes(NumFmt::Int4, 7), 4, "odd length rounds up");
        assert_eq!(row_bytes(NumFmt::Bf16, 8), 16);
        assert_eq!(row_bytes(NumFmt::Fp32, 8), 32);
    }

    /// The modelled ratios must stay rationals, so no format silently reports zero rate.
    #[test]
    fn mac_rate_ratios_are_nonzero_rationals() {
        for v in 0..8u32 {
            let f = NumFmt::from_abi(v).unwrap();
            let (num, den) = f.mac_rate_ratio();
            assert!(num > 0 && den > 0, "{} ratio {num}/{den}", f.as_str());
        }
        assert_eq!(NumFmt::Int4.mac_rate_ratio(), (2, 1));
        assert_eq!(NumFmt::Fp32.mac_rate_ratio(), (1, 4));
    }

    #[test]
    fn float_classification_matches_accumulator_choice() {
        assert!(!NumFmt::Int.is_float());
        assert!(!NumFmt::Int4.is_float());
        assert!(!NumFmt::Sp24.is_float());
        for f in [
            NumFmt::Fp8E4m3,
            NumFmt::Fp8E5m2,
            NumFmt::Fp16,
            NumFmt::Bf16,
            NumFmt::Fp32,
        ] {
            assert!(f.is_float(), "{} accumulates in f32", f.as_str());
        }
    }

    #[test]
    fn pack_c_round_trips_float_bits() {
        for bits in [0x7f80_0001, 0xffc1_2345, 0x7fff_ffff] {
            assert_eq!(pack_c(f32::from_bits(bits)), 0x7fc0_0000);
        }
        assert_eq!(pack_c(-0.0) as u32, 0x8000_0000);
        for v in [0.0f32, 1.0, -2.5, 1e10, -1e-10] {
            assert_eq!(f32::from_bits(pack_c(v) as u32), v);
        }
    }
}
