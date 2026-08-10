// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! IR ops → `Desc64` (no device I/O).
//! Enforces AccTile limits; optional host-side tiling for larger GEMMs.

use ai_tensor_abi::{AccTile, Desc64, FLAG_IRQ, OP_GEMM};
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
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DType {
    /// INT8 operands, INT32 accumulator in sim (island-class path).
    S8,
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
        match self.dtype {
            DType::S8 => {}
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
        Ok(d)
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
