// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
use ai_tensor_abi::{Desc64, NumFmt};
use crate::RtError;

pub const SOFTWARE_DTYPE_MASK: u16 = 0xfb;
pub const CANONICAL_NAN: u32 = 0x7fc00000;

pub fn check_format(fmt: NumFmt, mask: u16) -> Result<(), RtError> {
    if fmt == NumFmt::Sp24 || mask & fmt.grant_bit() == 0 {
        return Err(RtError::BadFmt);
    }
    Ok(())
}

pub fn desc_compute_numfmt(d: &Desc64) -> Result<NumFmt, RtError> {
    let dtype = (d.flags >> 8) & 3;
    let accmode = (d.flags >> 10) & 3;
    let ew = (d.flags >> 12) & 3;
    let sparse = (d.flags >> 14) & 1;
    let fmt = NumFmt::from_flags(d.flags).ok_or(RtError::BadFmt)?;
    if dtype != 0 || accmode != 0 || sparse != 0 || ew > 1 || fmt == NumFmt::Sp24 {
        return Err(RtError::BadFmt);
    }
    match fmt {
        NumFmt::Int if ew == 1 => Ok(NumFmt::Int4),
        NumFmt::Int | NumFmt::Int4 => Ok(fmt),
        _ if ew == 0 => Ok(fmt),
        _ => Err(RtError::BadFmt),
    }
}

pub fn check_desc_format(d: &Desc64, mask: u16) -> Result<(), RtError> {
    check_format(desc_compute_numfmt(d)?, mask)
}

/// Execution check. Float codes need `fp_datapath` in addition to the mask bit.
pub fn check_desc_engine(d: &Desc64, mask: u16, fp_datapath: bool) -> Result<(), RtError> {
    let fmt = desc_compute_numfmt(d)?;
    check_format(fmt, mask)?;
    let float = matches!(
        fmt,
        NumFmt::Fp8E4m3 | NumFmt::Fp8E5m2 | NumFmt::Fp16 | NumFmt::Bf16 | NumFmt::Fp32
    );
    if float && !fp_datapath {
        return Err(RtError::BadFmt);
    }
    Ok(())
}

#[derive(Clone, Copy)]
pub struct Layout {
    pub(crate) m: usize,
    pub(crate) n: usize,
    pub(crate) k: usize,
    pub(crate) stride_a: usize,
    pub(crate) stride_b: usize,
    pub(crate) a_bytes: usize,
    pub(crate) b_bytes: usize,
    pub(crate) c_bytes: usize,
    pub(crate) fmt: NumFmt,
}

impl Layout {
    pub fn new(m: u32, n: u32, k: u32, fmt: NumFmt, lda: u32, ldb: u32) -> Result<Self, RtError> {
        check_format(fmt, SOFTWARE_DTYPE_MASK)?;
        if m == 0 || n == 0 || k == 0 || lda < k || ldb < k || lda > 0xffff || ldb > 0xffff {
            return Err(RtError::BadPtr("shape/element stride"));
        }
        let stride_a = fmt.row_bytes(lda) as usize;
        let stride_b = fmt.row_bytes(ldb) as usize;
        let tail = fmt.row_bytes(k) as usize;
        let m = m as usize;
        let n = n as usize;
        Ok(Self {
            m, n, k: k as usize, stride_a, stride_b, fmt,
            a_bytes: (m - 1).checked_mul(stride_a).and_then(|x| x.checked_add(tail)).ok_or(RtError::BufferOob)?,
            b_bytes: (n - 1).checked_mul(stride_b).and_then(|x| x.checked_add(tail)).ok_or(RtError::BufferOob)?,
            c_bytes: m.checked_mul(n).and_then(|x| x.checked_mul(4)).ok_or(RtError::BufferOob)?,
        })
    }

    pub fn from_desc(d: &Desc64) -> Result<Self, RtError> {
        Self::new(d.m, d.n, d.k, desc_compute_numfmt(d)?, d.lda(), d.ldb())
    }

    pub fn validate(&self, a: &[u8], b: &[u8]) -> Result<(), RtError> {
        if a.len() < self.a_bytes || b.len() < self.b_bytes {
            return Err(RtError::BufferOob);
        }
        Ok(())
    }
}

pub fn decode_float(bits: u32, fmt: NumFmt) -> Result<f32, RtError> {
    let (eb, mb, bias) = match fmt {
        NumFmt::Fp32 => return Ok(f32::from_bits(bits)),
        NumFmt::Bf16 => return Ok(f32::from_bits((bits & 0xffff) << 16)),
        NumFmt::Fp8E4m3 => (4, 3, 7),
        NumFmt::Fp8E5m2 => (5, 2, 15),
        NumFmt::Fp16 => (5, 10, 15),
        _ => return Err(RtError::BadFmt),
    };
    let sign = ((bits >> (eb + mb)) & 1) << 31;
    let exp = (bits >> mb) & ((1 << eb) - 1);
    let mant = bits & ((1 << mb) - 1);
    if fmt == NumFmt::Fp8E4m3 {
        if exp == 15 && mant == 7 {
            return Ok(f32::from_bits(CANONICAL_NAN));
        }
    } else if exp == (1 << eb) - 1 {
        return Ok(f32::from_bits(if mant == 0 { sign | 0x7f800000 } else { CANONICAL_NAN }));
    }
    if exp == 0 {
        if mant == 0 {
            return Ok(f32::from_bits(sign));
        }
        let top = 31 - mant.leading_zeros();
        let e = 1 - bias - mb as i32 + top as i32 + 127;
        return Ok(f32::from_bits(sign | ((e as u32) << 23) | ((mant << (23 - top)) & 0x7fffff)));
    }
    Ok(f32::from_bits(sign | (((exp as i32 - bias + 127) as u32) << 23) | (mant << (23 - mb))))
}

fn raw(buf: &[u8], row: usize, t: usize, fmt: NumFmt) -> u32 {
    if fmt == NumFmt::Int4 {
        return u32::from((buf[row + t / 2] >> (4 * (t % 2))) & 15);
    }
    let size = fmt.elem_bytes().unwrap() as usize;
    let mut bytes = [0u8; 4];
    bytes[..size].copy_from_slice(&buf[row + t * size..row + (t + 1) * size]);
    u32::from_le_bytes(bytes)
}

#[inline(never)]
fn multiply(a: f32, b: f32) -> f32 { a * b }

#[inline(never)]
fn add(a: f32, b: f32) -> f32 { a + b }

pub fn gemm_native(a: &[u8], b: &[u8], layout: Layout) -> Result<Vec<u8>, RtError> {
    layout.validate(a, b)?;
    let mut out = vec![0u8; layout.c_bytes];
    for i in 0..layout.m {
        for j in 0..layout.n {
            let mut integer = 0i32;
            let mut float = 0.0f32;
            for t in 0..layout.k {
                let av = raw(a, i * layout.stride_a, t, layout.fmt);
                let bv = raw(b, j * layout.stride_b, t, layout.fmt);
                match layout.fmt {
                    NumFmt::Int | NumFmt::Int4 => {
                        let sh = if layout.fmt == NumFmt::Int4 { 28 } else { 24 };
                        let av = ((av << sh) as i32) >> sh;
                        let bv = ((bv << sh) as i32) >> sh;
                        integer = integer.wrapping_add(av.wrapping_mul(bv));
                    }
                    _ => {
                        let product = multiply(decode_float(av, layout.fmt)?, decode_float(bv, layout.fmt)?);
                        float = add(float, product);
                    }
                }
            }
            let bits = match layout.fmt {
                NumFmt::Int | NumFmt::Int4 => integer as u32,
                _ if float.is_nan() => CANONICAL_NAN,
                _ => float.to_bits(),
            };
            let off = (i * layout.n + j) * 4;
            out[off..off + 4].copy_from_slice(&bits.to_le_bytes());
        }
    }
    Ok(out)
}

pub(crate) fn memory_range(addr: u64, base: u64, len: usize, capacity: usize) -> Result<std::ops::Range<usize>, RtError> {
    let off = usize::try_from(addr.checked_sub(base).ok_or(RtError::BufferOob)?).map_err(|_| RtError::BufferOob)?;
    let end = off.checked_add(len).ok_or(RtError::BufferOob)?;
    if end > capacity { return Err(RtError::BufferOob); }
    Ok(off..end)
}

pub(crate) fn execute_memory(mem: &mut [u8], base: u64, d: &Desc64, compute: bool) -> Result<(), RtError> {
    let l = Layout::from_desc(d)?;
    let a = memory_range(d.ptr_a, base, l.a_bytes, mem.len())?;
    let b = memory_range(d.ptr_b, base, l.b_bytes, mem.len())?;
    let c = memory_range(d.ptr_c, base, l.c_bytes, mem.len())?;
    if compute {
        let out = gemm_native(&mem[a], &mem[b], l)?;
        mem[c].copy_from_slice(&out);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn descriptor_flags(fmt: u32, dtype: u32, accmode: u32, ew: u32, sparse: u32) -> u32 {
        (fmt << ai_tensor_abi::FLAG_NUMFMT_SHIFT)
            | (dtype << 8) | (accmode << 10) | (ew << 12) | (sparse << 14)
    }

    #[test]
    fn descriptor_accmode_fails_closed() {
        let mut d = Desc64::gemm(1, 1, 1);
        d.flags = descriptor_flags(0, 0, 1, 0, 0);
        assert!(matches!(Layout::from_desc(&d), Err(RtError::BadFmt)));
    }

    #[test]
    fn descriptor_modes_fail_closed_before_writing_c() {
        for flags in [descriptor_flags(0, 1, 0, 0, 0), descriptor_flags(0, 0, 1, 0, 0)] {
            let mut d = Desc64::gemm(1, 1, 1).with_ptrs(0, 4, 8, 0);
            d.flags = flags;
            let mut mem = [0xa5; 16];
            let before = mem;
            assert!(matches!(execute_memory(&mut mem, 0, &d, true), Err(RtError::BadFmt)),
                    "unsupported flags={flags:#x}");
            assert_eq!(mem, before);
        }
    }

    #[test]
    fn descriptor_modes_exhaustive() {
        let mut count = 0;
        for fmt in 0..8 {
            for dtype in 0..4 {
                for accmode in 0..4 {
                    for ew in 0..4 {
                        for sparse in 0..2 {
                            let mut d = Desc64::gemm(1, 1, 1);
                            d.flags = descriptor_flags(fmt, dtype, accmode, ew, sparse);
                            let legal = dtype == 0 && accmode == 0 && sparse == 0
                                && fmt != 2 && ew < 2 && (fmt < 3 || ew == 0);
                            let effective = if fmt == 0 && ew == 1 { 1 } else { fmt };
                            for mask in [1, 2, 3, 0xf9, 0xfb, 0xff] {
                                assert_eq!(check_desc_format(&d, mask).is_ok(),
                                    legal && mask & (1 << effective) != 0,
                                    "flags={:#x} mask={mask:#x}", d.flags);
                            }
                            let layout = Layout::from_desc(&d);
                            assert_eq!(layout.is_ok(), legal, "flags={:#x}", d.flags);
                            if let Ok(layout) = layout {
                                assert_eq!(layout.fmt, NumFmt::from_abi(effective).unwrap());
                                for mask in [1, 2, 3, 0xfb, 0xff] {
                                    assert_eq!(check_format(layout.fmt, mask).is_ok(),
                                               mask & (1 << effective) != 0);
                                }
                            }
                            count += 1;
                        }
                    }
                }
            }
        }
        assert_eq!(count, 1024);
    }

    #[test]
    fn descriptor_int4_aliases_compute_odd_k_padded_rows() {
        // A=[[-1,2,3],[4,-5,6]], B=[[2,-3,4],[-1,2,-2]], K=3.
        // Each row has a poisoned unused high nibble and a padded byte (ld=5).
        for (fmt, ew) in [(0, 1), (1, 0), (1, 1)] {
            let mut d = Desc64::gemm(2, 2, 3).with_ptrs(0, 16, 32, 0);
            d.ld_ab = 5 | (5 << 16);
            d.flags = descriptor_flags(fmt, 0, 0, ew, 0);
            let mut mem = [0xa5; 64];
            mem[..6].copy_from_slice(&[0x2f, 0xe3, 0xab, 0xb4, 0xe6, 0xcd]);
            mem[16..22].copy_from_slice(&[0xd2, 0xe4, 0xab, 0x2f, 0xee, 0xcd]);
            execute_memory(&mut mem, 0, &d, true).unwrap();
            let want: Vec<u8> = [4i32, -1, 47, -26].iter().flat_map(|v| v.to_le_bytes()).collect();
            assert_eq!(&mem[32..48], want, "fmt={fmt} ew={ew}");
            assert_eq!(NumFmt::from_flags(d.flags), NumFmt::from_abi(fmt), "raw ABI accessor");
        }
    }

    #[test]
    fn special_decode() {
        assert_eq!(decode_float(0x78, NumFmt::Fp8E4m3).unwrap(), 256.0);
        assert_eq!(decode_float(0x7e, NumFmt::Fp8E4m3).unwrap(), 448.0);
        assert!(decode_float(0x7f, NumFmt::Fp8E4m3).unwrap().is_nan());
        assert_eq!(decode_float(0x80, NumFmt::Fp8E5m2).unwrap().to_bits(), 0x80000000);
        assert_eq!(decode_float(1, NumFmt::Fp16).unwrap(), 2.0f32.powi(-24));
    }

    #[test]
    fn ordered_nonfused() {
        let a: Vec<u8> = [0xbf800000u32, 0x3f800001].iter().flat_map(|v| v.to_le_bytes()).collect();
        let b: Vec<u8> = [0x3f800000u32, 0x3f7fffff].iter().flat_map(|v| v.to_le_bytes()).collect();
        let l = Layout::new(1, 1, 2, NumFmt::Fp32, 2, 2).unwrap();
        assert_eq!(gemm_native(&a, &b, l).unwrap(), [0, 0, 0, 0]);
    }
}
