// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Exact operand reuse. Off unless enabled.
//!
//! A hit multiplies the bytes captured when the key was installed. The key
//! matches `g6lc_ai_gemm_seq`: B is pointer, N, K, ldb, format, and epoch.
//! A is pointer, M, K, lda, format, and epoch. N is not in the A key and M
//! is not in the B key. A C range that meets the operand does not hit and
//! drops that key. A failed dot drops both keys.

use ai_tensor_abi::{Desc64, FLAG_NUMFMT_SHIFT, FLAG_REUSE_A, FLAG_REUSE_B};

use crate::numfmt::{self, Layout};
use crate::RtError;

#[derive(Clone, Debug)]
struct Resident {
    ptr: u64,
    rows: u32,
    k: u32,
    ld: u32,
    fmt: u32,
    epoch: u32,
    bytes: Vec<u8>,
}

impl Resident {
    fn matches(&self, ptr: u64, rows: u32, k: u32, ld: u32, fmt: u32, epoch: u32, len: usize) -> bool {
        self.ptr == ptr
            && self.rows == rows
            && self.k == k
            && self.ld == ld
            && self.fmt == fmt
            && self.epoch == epoch
            && self.bytes.len() == len
    }
}

#[derive(Clone, Debug, Default)]
pub(crate) struct OperandReuse {
    enabled: bool,
    a: Option<Resident>,
    b: Option<Resident>,
}

impl OperandReuse {
    pub(crate) fn set_enabled(&mut self, on: bool) {
        self.enabled = on;
        if !on {
            self.a = None;
            self.b = None;
        }
    }

    pub(crate) fn enabled(&self) -> bool {
        self.enabled
    }

    fn drop_both(&mut self) {
        self.a = None;
        self.b = None;
    }
}

pub(crate) struct ReuseObs {
    pub read_a: bool,
    pub read_b: bool,
}

fn numfmt_key(flags: u32) -> u32 {
    (flags >> FLAG_NUMFMT_SHIFT) & 7
}

fn disjoint(op: u64, op_len: u64, c: u64, c_len: u64) -> bool {
    let op_end = match (op as u128).checked_add(op_len as u128) {
        Some(v) => v,
        None => return false,
    };
    let c_end = match (c as u128).checked_add(c_len as u128) {
        Some(v) => v,
        None => return false,
    };
    c_end <= op as u128 || op_end <= c as u128
}

/// Run one GEMM. With reuse disabled this is the ordinary memory dot.
pub(crate) fn execute(
    reuse: &mut OperandReuse,
    epoch: u32,
    mem: &mut [u8],
    base: u64,
    d: &Desc64,
    compute: bool,
) -> Result<ReuseObs, RtError> {
    if !reuse.enabled || !compute {
        numfmt::execute_memory(mem, base, d, compute)?;
        return Ok(ReuseObs {
            read_a: true,
            read_b: true,
        });
    }
    let layout = Layout::from_desc(d)?;
    let a_range = numfmt::memory_range(d.ptr_a, base, layout.a_bytes, mem.len())?;
    let b_range = numfmt::memory_range(d.ptr_b, base, layout.b_bytes, mem.len())?;
    let c_range = numfmt::memory_range(d.ptr_c, base, layout.c_bytes, mem.len())?;
    let fmt = numfmt_key(d.flags);
    let a_ok = disjoint(d.ptr_a, layout.a_bytes as u64, d.ptr_c, layout.c_bytes as u64);
    let b_ok = disjoint(d.ptr_b, layout.b_bytes as u64, d.ptr_c, layout.c_bytes as u64);
    let hit_a = d.flags & FLAG_REUSE_A != 0
        && a_ok
        && reuse.a.as_ref().is_some_and(|r| {
            r.matches(d.ptr_a, d.m, d.k, d.lda(), fmt, epoch, layout.a_bytes)
        });
    let hit_b = d.flags & FLAG_REUSE_B != 0
        && b_ok
        && reuse.b.as_ref().is_some_and(|r| {
            r.matches(d.ptr_b, d.n, d.k, d.ldb(), fmt, epoch, layout.b_bytes)
        });
    let a_bytes = match reuse.a.as_ref() {
        Some(r) if hit_a => r.bytes.clone(),
        _ => mem[a_range].to_vec(),
    };
    let b_bytes = match reuse.b.as_ref() {
        Some(r) if hit_b => r.bytes.clone(),
        _ => mem[b_range].to_vec(),
    };
    let seed = if numfmt::desc_accumulate(d)? { Some(mem[c_range.clone()].to_vec()) } else { None };
    let out = match numfmt::gemm_native_acc(&a_bytes, &b_bytes, layout, seed.as_deref()) {
        Ok(out) => out,
        Err(err) => {
            reuse.drop_both();
            return Err(err);
        }
    };
    mem[c_range].copy_from_slice(&out);
    if a_ok {
        reuse.a = Some(Resident {
            ptr: d.ptr_a,
            rows: d.m,
            k: d.k,
            ld: d.lda(),
            fmt,
            epoch,
            bytes: a_bytes,
        });
    } else {
        reuse.a = None;
    }
    if b_ok {
        reuse.b = Some(Resident {
            ptr: d.ptr_b,
            rows: d.n,
            k: d.k,
            ld: d.ldb(),
            fmt,
            epoch,
            bytes: b_bytes,
        });
    } else {
        reuse.b = None;
    }
    Ok(ReuseObs {
        read_a: !hit_a,
        read_b: !hit_b,
    })
}
