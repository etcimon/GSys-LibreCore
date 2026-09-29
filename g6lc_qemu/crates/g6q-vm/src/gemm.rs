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
//! | exact operand reuse when `OperandReuse` is enabled | reuse while that switch is off |
//! | the shape bound the engine enforces, and the status it returns | cycles, bandwidth, or any latency |
//! | refusal of arithmetic modes the capability window does not grant | the modes themselves |
//!
//! [`run_va_turbo_test_s8`] turns that switch on only for the 8-MAC
//! 1024×512×16 model, and only when a planned tile can skip an operand.
//! A 512-MAC model is refused. The schedule does not apply a VA level.
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
    /// The dot finished. A refusal leaves this clear so residency is left alone.
    pub ran_gemm: bool,
    /// False when resident A supplied the operand.
    pub read_a: bool,
    /// False when resident B supplied the operand.
    pub read_b: bool,
    /// A image to keep after a successful dot. Empty means that key drops.
    pub install_a: Option<ResidentOperand>,
    /// B image to keep after a successful dot. Empty means that key drops.
    pub install_b: Option<ResidentOperand>,
}

/// One captured operand. The key matches `g6lc_ai_gemm_seq`: pointer, the
/// dimension that addresses it, K, the leading dimension, format, and epoch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResidentOperand {
    ptr: u64,
    rows: u32,
    k: u32,
    ld: u32,
    fmt: u32,
    epoch: u32,
    bytes: Vec<u8>,
}

impl ResidentOperand {
    fn matches(
        &self,
        ptr: u64,
        rows: u32,
        k: u32,
        ld: u32,
        fmt: u32,
        epoch: u32,
        len: u64,
    ) -> bool {
        self.ptr == ptr
            && self.rows == rows
            && self.k == k
            && self.ld == ld
            && self.fmt == fmt
            && self.epoch == epoch
            && self.bytes.len() as u64 == len
    }
}

/// Exact operand reuse for the guest model. Off until [`OperandReuse::set_enabled`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OperandReuse {
    enabled: bool,
    /// Epoch compared with the resident key. A different epoch misses.
    pub epoch: u32,
    a: Option<ResidentOperand>,
    b: Option<ResidentOperand>,
    /// Whether the last finished dot read A from guest memory.
    pub last_read_a: bool,
    /// Whether the last finished dot read B from guest memory.
    pub last_read_b: bool,
}

impl Default for OperandReuse {
    fn default() -> Self {
        Self {
            enabled: false,
            epoch: 0,
            a: None,
            b: None,
            last_read_a: true,
            last_read_b: true,
        }
    }
}

impl OperandReuse {
    /// Turn residency on. Turning it off drops both keys.
    pub fn set_enabled(&mut self, on: bool) {
        self.enabled = on;
        if !on {
            self.a = None;
            self.b = None;
        }
    }

    /// Drop both keys. A failed C store uses this.
    pub fn drop_both(&mut self) {
        self.a = None;
        self.b = None;
    }

    /// Record whether the dot read each operand from guest memory.
    pub fn observe(&mut self, read_a: bool, read_b: bool) {
        self.last_read_a = read_a;
        self.last_read_b = read_b;
    }

    /// Keep the images from a finished dot. A missing image drops that key.
    pub fn commit(&mut self, job: &AiJobResult) {
        if !self.enabled || !job.ran_gemm {
            return;
        }
        self.a = job.install_a.clone();
        self.b = job.install_b.clone();
    }
}

/// `g6lc_ai_desc_pkg` flag shifts. They are descriptor bits, not status codes.
const FLAG_REUSE_B: u32 = 1 << 15;
const FLAG_REUSE_A: u32 = 1 << 23;

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
    #[doc = "A DMA pointer is unaligned, overflows, or is not backed by writable normal RAM."]
    BadPointer,
}

impl AiJobReject {
    /// Stable wire name, for traces and reports.
    pub fn as_str(self) -> &'static str {
        match self {
            AiJobReject::BadVersion => "bad-version",
            AiJobReject::BadOp => "bad-op",
            AiJobReject::BadShape => "bad-shape",
            AiJobReject::UngrantedDtype => "ungranted-dtype",
            AiJobReject::BadPointer => "bad-pointer",
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

fn numfmt_key(model: &AiIslandModel, flags: u32) -> u32 {
    model
        .desc_layout
        .flags_layout
        .and_then(|fl| fl.numfmt)
        .map(|field| field.extract(flags))
        .unwrap_or(0)
}

fn ranges_disjoint(op: u64, op_len: u64, c: u64, c_len: u64) -> bool {
    let Some(op_end) = (op as u128).checked_add(op_len as u128) else {
        return false;
    };
    let Some(c_end) = (c as u128).checked_add(c_len as u128) else {
        return false;
    };
    c_end <= op as u128 || op_end <= c as u128
}

fn snapshot_bytes(mem: &PhysMem, ptr: u64, len: u64) -> Option<Vec<u8>> {
    let _ = usize::try_from(len).ok()?;
    let mut out = Vec::with_capacity(len as usize);
    for i in 0..len {
        out.push(mem.read_le::<1>(ptr + i).ok()? as u8);
    }
    Some(out)
}

pub(crate) fn bad_pointer_status(model: &AiIslandModel) -> u16 {
    status_of(model, "ST_BAD_PTR", status_of(model, ST_ERR, 1))
}

pub(crate) fn completion_writable(mem: &PhysMem, ptr: u64) -> bool {
    ptr == 0 || (ptr % 8 == 0 && mem.is_ram_range(ptr, 8))
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
    if let (Some(_), Some(accmode), Some(ew), Some(sp24)) =
        (fl.numfmt, fl.accmode, fl.ew, fl.sp24_bit)
    {
        let dtype = (flags >> fl.dtype_shift) & fl.dtype_mask;
        return Some(
            dtype != 0
                || accmode.extract(flags) != 0
                || ew.extract(flags) > 1
                || ((flags >> sp24) & 1) != 0,
        );
    }
    // Compatibility for older, partially unresolved layouts; never guess field positions.
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
    if fl
        .sp24_bit
        .is_some_and(|bit| bit < 32 && flags & (1 << bit) != 0)
    {
        return Err(AiJobReject::UngrantedDtype);
    }
    let Some(field) = fl.numfmt else {
        return Ok(NumFmt::Int);
    };
    let raw = field.extract(flags);
    let mut fmt = NumFmt::from_abi(raw).ok_or(AiJobReject::UngrantedDtype)?;
    if !fl.dtype_combined {
        if let Some(ew) = fl.ew {
            let ew = ew.extract(flags);
            if ew > 1 || (fmt.is_float() && ew != 0) {
                return Err(AiJobReject::UngrantedDtype);
            }
            if fmt == NumFmt::Int && ew == 1 {
                fmt = NumFmt::Int4;
            }
        }
    }
    // Absent a published mask, assume the frozen baseline: dense INT8 only. Assuming
    // everything is granted would make the emulator compute formats the design refuses,
    // which is the one divergence that cannot be caught by comparing results.
    let granted = model.config.dtype_mask.unwrap_or(1);
    if fmt == NumFmt::Sp24 || (granted >> fmt.grant_bit()) & 1 == 0 {
        return Err(AiJobReject::UngrantedDtype);
    }
    // The mask can name a float the integer strip does not multiply.
    if fmt.is_float() && !model.config.fp_datapath {
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
    execute_with(mem, ev, model, None)
}

/// Same as [`execute`], using `resident` when it is enabled.
pub fn execute_with(
    mem: &PhysMem,
    ev: &AiTensorEvent,
    model: &AiIslandModel,
    resident: Option<&OperandReuse>,
) -> AiJobResult {
    match plan_with(mem, ev, model, resident) {
        Ok(r) => r,
        Err((reject, status)) => {
            let _ = reject;
            AiJobResult {
                status,
                c_writes: Vec::new(),
                skipped: false,
                ..AiJobResult::default()
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
    plan_with(mem, ev, model, None)
}

fn plan_with(
    mem: &PhysMem,
    ev: &AiTensorEvent,
    model: &AiIslandModel,
    resident: Option<&OperandReuse>,
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
        if !completion_writable(mem, ev.ptr_done) {
            return Err((AiJobReject::BadPointer, bad_pointer_status(model)));
        }
        return Ok(AiJobResult {
            status: ok,
            c_writes: Vec::new(),
            skipped: true,
            ..AiJobResult::default()
        });
    }

    // ---- arithmetic mode -------------------------------------------------------------
    // Two checks, not one. `requests_ungranted_mode` covers the legacy `ew`/`sp24`/`dtype`
    // levers; `resolve_numfmt` covers the numeric-format field. Both must refuse, because a
    // descriptor can express an ungranted mode either way and demoting silently to INT8
    // would return numerically plausible results for the wrong arithmetic.
    if requests_ungranted_mode(model, ev.flags) == Some(true) {
        return Err((
            AiJobReject::UngrantedDtype,
            status_of(model, ST_BAD_FMT, status_of(model, ST_ERR, 1)),
        ));
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

    let bad = |model: &AiIslandModel| (AiJobReject::BadPointer, bad_pointer_status(model));
    let span = |rows: u64, stride: u64| {
        (rows - 1)
            .checked_mul(stride)
            .and_then(|v| v.checked_add(row_bytes(fmt, k)))
            .ok_or_else(|| bad(model))
    };
    let a_len = span(m, a_row_stride)?;
    let b_len = span(n, b_row_stride)?;
    ev.ptr_a.checked_add(a_len).ok_or_else(|| bad(model))?;
    ev.ptr_b.checked_add(b_len).ok_or_else(|| bad(model))?;
    let c_len = m
        .checked_mul(n)
        .and_then(|v| v.checked_mul(4))
        .ok_or_else(|| bad(model))?;
    if ev.ptr_c % 4 != 0
        || !mem.is_ram_range(ev.ptr_c, c_len)
        || !completion_writable(mem, ev.ptr_done)
    {
        return Err(bad(model));
    }
    let fmt_key = numfmt_key(model, ev.flags);
    let a_disj = ranges_disjoint(ev.ptr_a, a_len, ev.ptr_c, c_len);
    let b_disj = ranges_disjoint(ev.ptr_b, b_len, ev.ptr_c, c_len);
    let active = resident.filter(|r| r.enabled);
    let take = |slot: Option<&ResidentOperand>,
                flag: u32,
                disj: bool,
                ptr: u64,
                rows: u32,
                ld: u32,
                len: u64| {
        active.and_then(|r| {
            if ev.flags & flag == 0 || !disj {
                return None;
            }
            slot.filter(|op| op.matches(ptr, rows, ev.k, ld, fmt_key, r.epoch, len))
                .map(|op| op.bytes.clone())
        })
    };
    let cached_a = take(
        active.and_then(|r| r.a.as_ref()),
        FLAG_REUSE_A,
        a_disj,
        ev.ptr_a,
        ev.m,
        lda,
        a_len,
    );
    let cached_b = take(
        active.and_then(|r| r.b.as_ref()),
        FLAG_REUSE_B,
        b_disj,
        ev.ptr_b,
        ev.n,
        ldb,
        b_len,
    );
    let prefetch = cached_a.is_none()
        && cached_b.is_none()
        && mem.is_ram_range(ev.ptr_a, a_len)
        && mem.is_ram_range(ev.ptr_b, b_len)
        && (m + n)
            .checked_mul(k)
            .is_some_and(|v| v <= 16 * 1024 * 1024);
    let decode = |base: u64, rows: u64, stride: u64| -> Result<Vec<Elem>, (AiJobReject, u16)> {
        let mut values = Vec::with_capacity((rows * k) as usize);
        for row in 0..rows {
            for t in 0..k {
                values.push(
                    read_elem(fmt, base + row * stride, t, |addr| {
                        mem.read_le::<1>(addr).ok().map(|v| v as u8)
                    })
                    .ok_or_else(|| bad(model))?,
                );
            }
        }
        Ok(values)
    };
    let (a_values, b_values) = if prefetch {
        (
            decode(ev.ptr_a, m, a_row_stride)?,
            decode(ev.ptr_b, n, b_row_stride)?,
        )
    } else {
        (Vec::new(), Vec::new())
    };
    let mut c_writes = Vec::with_capacity((m * n) as usize);
    for i in 0..m {
        let a_row = ev.ptr_a + i * a_row_stride;
        for j in 0..n {
            // One accumulator per kind. Integer modes sum in i32 and float modes in f32,
            // matching the 32-bit `C` the ABI defines; see the numfmt module note on why a
            // wider accumulator would make the model less useful as a golden, not more.
            let mut acc_i: i32 = 0;
            let mut acc_f: f32 = 0.0;
            for t in 0..k {
                let rd = |addr: u64| mem.read_le::<1>(addr).ok().map(|v| v as u8);
                let a = if let Some(bytes) = cached_a.as_deref() {
                    read_elem(fmt, a_row, t, |addr| {
                        let off = usize::try_from(addr.checked_sub(ev.ptr_a)?).ok()?;
                        bytes.get(off).copied()
                    })
                    .ok_or_else(|| bad(model))?
                } else if prefetch {
                    a_values[(i * k + t) as usize]
                } else {
                    read_elem(fmt, a_row, t, rd).ok_or_else(|| bad(model))?
                };
                // B is k-major, so its row base is fixed by `j` for the whole reduction and
                // the element index within the row is `t` -- exactly like A. `read_elem` is
                // index-based and needs no change for either operand or any format.
                let b_row = ev.ptr_b + j * b_row_stride;
                let b = if let Some(bytes) = cached_b.as_deref() {
                    read_elem(fmt, b_row, t, |addr| {
                        let off = usize::try_from(addr.checked_sub(ev.ptr_b)?).ok()?;
                        bytes.get(off).copied()
                    })
                    .ok_or_else(|| bad(model))?
                } else if prefetch {
                    b_values[(j * k + t) as usize]
                } else {
                    read_elem(fmt, b_row, t, rd).ok_or_else(|| bad(model))?
                };
                match (a, b) {
                    (Elem::Int(x), Elem::Int(y)) => {
                        acc_i = acc_i.wrapping_add(x.wrapping_mul(y));
                    }
                    (Elem::Float(x), Elem::Float(y)) => {
                        let product = x * y;
                        acc_f += product;
                    }
                    // read_elem derives the element kind from `fmt` alone, so a mixed pair is
                    // structurally impossible. Refuse rather than pick one: a silent choice
                    // here would be an arithmetic error dressed as a result.
                    _ => return Err(bad(model)),
                }
            }
            let c_addr = ev.ptr_c + (i * n + j) * 4;
            c_writes.push((c_addr, if fmt.is_float() { pack_c(acc_f) } else { acc_i }));
        }
    }

    let epoch = active.map(|r| r.epoch).unwrap_or(0);
    let install = |cached: &Option<Vec<u8>>, disj: bool, ptr: u64, rows: u32, ld: u32, len: u64| {
        if active.is_none() {
            return Ok(None);
        }
        if !disj {
            return Ok(None);
        }
        let bytes = if let Some(bytes) = cached {
            bytes.clone()
        } else {
            snapshot_bytes(mem, ptr, len).ok_or_else(|| bad(model))?
        };
        Ok(Some(ResidentOperand {
            ptr,
            rows,
            k: ev.k,
            ld,
            fmt: fmt_key,
            epoch,
            bytes,
        }))
    };
    Ok(AiJobResult {
        status: ok,
        c_writes,
        skipped: false,
        ran_gemm: true,
        read_a: cached_a.is_none(),
        read_b: cached_b.is_none(),
        install_a: install(&cached_a, a_disj, ev.ptr_a, ev.m, lda, a_len)?,
        install_b: install(&cached_b, b_disj, ev.ptr_b, ev.n, ldb, b_len)?,
    })
}

/// MAC issue width of the directed VA-Turbo test model. Not the live package.
const VA_TURBO_TEST_MACS: u32 = 8;

struct Panel {
    m: u32,
    n: u32,
    k: u32,
}

struct Block {
    i0: u32,
    j0: u32,
    t0: u32,
    tm: u32,
    tn: u32,
    tk: u32,
}

/// Outcome of [`run_va_turbo_test_s8`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VaTurboTestRun {
    /// Full i32 product, row-major.
    pub c: Vec<i32>,
    /// Flag word for each tile. Bit 15 skips B. Bit 23 skips A.
    pub flags: Vec<u32>,
    /// Whether the last tile read A from guest memory.
    pub read_a: bool,
    /// Whether the last tile read B from guest memory.
    pub read_b: bool,
    /// True when any tile skipped A.
    pub hit_a: bool,
    /// True when any tile skipped B.
    pub hit_b: bool,
    /// True when a planned tile can skip, which is when reuse is enabled.
    pub reuse_enabled: bool,
}

/// True when `model` is the directed 8-MAC 1024×512×16 tile.
pub fn directed_va_turbo_model(model: &AiIslandModel) -> bool {
    let c = &model.config;
    c.macs_per_cycle == VA_TURBO_TEST_MACS
        && c.acc_tile_m == 1024
        && c.acc_tile_n == 512
        && c.acc_tile_k == 16
}

fn va_panels(macs: u32) -> Vec<Panel> {
    if macs < 4 || macs % 4 != 0 {
        return Vec::new();
    }
    let half = macs / 2;
    let quarter = macs / 4;
    vec![
        Panel {
            m: macs,
            n: macs,
            k: macs,
        },
        Panel {
            m: macs,
            n: half,
            k: macs,
        },
        Panel {
            m: macs.saturating_mul(2),
            n: quarter,
            k: macs,
        },
    ]
}

fn div_ceil(n: u32, d: u32) -> Option<u64> {
    if d == 0 {
        return None;
    }
    Some(u64::from(n).div_ceil(u64::from(d)))
}

/// Same choice as the host `va_blocking_tile`: fewest tiles, then the most
/// exact panels, then the wider N.
fn blocking_panel(m: u32, n: u32, k: u32, cap_m: u32, cap_n: u32, cap_k: u32, macs: u32) -> Panel {
    let mut best: Option<(u64, u64, u32, Panel)> = None;
    for panel in va_panels(macs) {
        if panel.m == 0
            || panel.n == 0
            || panel.k == 0
            || panel.m > cap_m
            || panel.n > cap_n
            || panel.k > cap_k
        {
            continue;
        }
        let (Some(tm), Some(tn), Some(tk)) = (
            div_ceil(m, panel.m),
            div_ceil(n, panel.n),
            div_ceil(k, panel.k),
        ) else {
            continue;
        };
        let Some(tiles) = tm.checked_mul(tn).and_then(|x| x.checked_mul(tk)) else {
            continue;
        };
        let exact_m = if m % panel.m == 0 {
            tm
        } else {
            tm.saturating_sub(1)
        };
        let exact_n = if n % panel.n == 0 {
            tn
        } else {
            tn.saturating_sub(1)
        };
        let named = exact_m.saturating_mul(exact_n).saturating_mul(tk);
        let replace = match &best {
            None => true,
            Some((bt, bn, bw, _)) => {
                tiles < *bt || (tiles == *bt && (named > *bn || (named == *bn && panel.n > *bw)))
            }
        };
        if replace {
            best = Some((tiles, named, panel.n, panel));
        }
    }
    best.map(|(_, _, _, panel)| panel).unwrap_or(Panel {
        m: cap_m,
        n: cap_n,
        k: cap_k,
    })
}

fn tile_blocks(m: u32, n: u32, k: u32, panel: &Panel) -> Vec<Block> {
    let mut out = Vec::new();
    if m == 0 || n == 0 || k == 0 || panel.m == 0 || panel.n == 0 || panel.k == 0 {
        return out;
    }
    let mut i = 0u32;
    while i < m {
        let tm = (m - i).min(panel.m);
        let mut j = 0u32;
        while j < n {
            let tn = (n - j).min(panel.n);
            let mut t = 0u32;
            while t < k {
                let tk = (k - t).min(panel.k);
                out.push(Block {
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

/// One tile of the directed schedule, including the reuse flags it requests.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VaTurboTile {
    /// Row origin in the full A matrix.
    pub i0: u32,
    /// Column origin in the full B matrix.
    pub j0: u32,
    /// K origin.
    pub t0: u32,
    /// Tile M.
    pub tm: u32,
    /// Tile N.
    pub tn: u32,
    /// Tile K.
    pub tk: u32,
    /// Bit 15 skips B. Bit 23 skips A.
    pub flags: u32,
}

/// Tile list for the directed model. Other capability records are refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VaTurboPlan {
    /// Tiles in schedule order.
    pub tiles: Vec<VaTurboTile>,
    /// True when a tile carries a skip, which is when reuse is enabled.
    pub reuse_enabled: bool,
}

/// Plan the directed schedule without executing it.
///
/// The live 512-MAC record is refused. Exact reuse is enabled only when a
/// planned tile can skip an operand.
pub fn plan_va_turbo_tiles(
    model: &AiIslandModel,
    m: u32,
    n: u32,
    k: u32,
) -> Result<VaTurboPlan, &'static str> {
    if !directed_va_turbo_model(model) {
        return Err("VaTurbo test schedule requires the 8-MAC 1024x512x16 directed tile");
    }
    if m == 0 || n == 0 || k == 0 {
        return Err("invalid shape");
    }
    let cap = &model.config;
    let panel = blocking_panel(
        m,
        n,
        k,
        cap.acc_tile_m,
        cap.acc_tile_n,
        cap.acc_tile_k,
        cap.macs_per_cycle,
    );
    let blocks = tile_blocks(m, n, k, &panel);
    if blocks.is_empty() {
        return Err("empty tile plan");
    }
    let mut flags = vec![0u32; blocks.len()];
    let mut can_skip = false;
    for idx in 1..blocks.len() {
        let prev = &blocks[idx - 1];
        let tile = &blocks[idx];
        if prev.j0 == tile.j0 && prev.tn == tile.tn && prev.t0 == tile.t0 && prev.tk == tile.tk {
            flags[idx] |= FLAG_REUSE_B;
            can_skip = true;
        }
        if prev.i0 == tile.i0 && prev.tm == tile.tm && prev.t0 == tile.t0 && prev.tk == tile.tk {
            flags[idx] |= FLAG_REUSE_A;
            can_skip = true;
        }
    }
    let tiles = blocks
        .into_iter()
        .zip(flags)
        .map(|(tile, flags)| VaTurboTile {
            i0: tile.i0,
            j0: tile.j0,
            t0: tile.t0,
            tm: tile.tm,
            tn: tile.tn,
            tk: tile.tk,
            flags,
        })
        .collect();
    Ok(VaTurboPlan {
        tiles,
        reuse_enabled: can_skip,
    })
}

/// Directed schedule on the guest model.
///
/// `mem` already holds A row-major `[m][k]` at `ptr_a` and B k-major `[n][k]`
/// at `ptr_b`. `ptr_c` is a scratch the tiles share; the returned `c` is the
/// accumulated product. The default and the live 512-MAC records are refused.
/// Exact reuse is enabled only when a planned tile can skip an operand.
pub fn run_va_turbo_test_s8(
    model: &AiIslandModel,
    mem: &PhysMem,
    m: u32,
    n: u32,
    k: u32,
    ptr_a: u64,
    ptr_b: u64,
    ptr_c: u64,
) -> Result<VaTurboTestRun, &'static str> {
    let plan = plan_va_turbo_tiles(model, m, n, k)?;
    let flags: Vec<u32> = plan.tiles.iter().map(|tile| tile.flags).collect();
    let mut cache = OperandReuse::default();
    cache.set_enabled(plan.reuse_enabled);
    let version = u16::try_from(model.desc_layout.version.unwrap_or(1)).unwrap_or(1);
    let op = u16::try_from(model.desc_layout.op(OP_GEMM).unwrap_or(1)).unwrap_or(1);
    let cells = (m as usize)
        .checked_mul(n as usize)
        .ok_or("invalid shape")?;
    let mut c = vec![0i32; cells];
    let mut read_a = true;
    let mut read_b = true;
    let mut hit_a = false;
    let mut hit_b = false;
    for tile in &plan.tiles {
        let ev = AiTensorEvent {
            version,
            op,
            m: tile.tm,
            n: tile.tn,
            k: tile.tk,
            ld_ab: k | (k << 16),
            flags: tile.flags,
            ptr_a: ptr_a + u64::from(tile.i0) * u64::from(k) + u64::from(tile.t0),
            ptr_b: ptr_b + u64::from(tile.j0) * u64::from(k) + u64::from(tile.t0),
            ptr_c,
            ..Default::default()
        };
        let job =
            plan_with(mem, &ev, model, Some(&cache)).map_err(|_| "directed tile job failed")?;
        if job.status != status_of(model, ST_OK, 0) || !job.ran_gemm {
            return Err("directed tile job failed");
        }
        let need = (tile.tm as usize)
            .checked_mul(tile.tn as usize)
            .ok_or("invalid shape")?;
        if job.c_writes.len() != need {
            return Err("directed tile job failed");
        }
        for ii in 0..tile.tm as usize {
            for jj in 0..tile.tn as usize {
                let value = job.c_writes[ii * tile.tn as usize + jj].1;
                let dst = (tile.i0 as usize + ii) * n as usize + (tile.j0 as usize + jj);
                c[dst] = c[dst].wrapping_add(value);
            }
        }
        read_a = job.read_a;
        read_b = job.read_b;
        hit_a |= !job.read_a;
        hit_b |= !job.read_b;
        cache.observe(job.read_a, job.read_b);
        cache.commit(&job);
    }
    Ok(VaTurboTestRun {
        c,
        flags,
        read_a,
        read_b,
        hit_a,
        hit_b,
        reuse_enabled: plan.reuse_enabled,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mem::{PhysMem, Region};
    use g6q_core::model::{AiDescLayout, AiIslandConfig, DescField};

    fn scalar_baseline(mem: &PhysMem, ev: &AiTensorEvent, fmt: NumFmt) -> Vec<(u64, i32)> {
        let (lda, ldb) = (ev.ld_ab & 0xffff, ev.ld_ab >> 16);
        let mut out = Vec::new();
        for i in 0..ev.m as u64 {
            for j in 0..ev.n as u64 {
                let (mut integer, mut float) = (0i32, 0f32);
                for t in 0..ev.k as u64 {
                    let rd = |addr| mem.read_le::<1>(addr).ok().map(|b| b as u8);
                    let a =
                        read_elem(fmt, ev.ptr_a + i * row_bytes(fmt, lda as u64), t, rd).unwrap();
                    let b =
                        read_elem(fmt, ev.ptr_b + j * row_bytes(fmt, ldb as u64), t, rd).unwrap();
                    match (a, b) {
                        (Elem::Int(a), Elem::Int(b)) => {
                            integer = integer.wrapping_add(a.wrapping_mul(b))
                        }
                        (Elem::Float(a), Elem::Float(b)) => {
                            let product = a * b;
                            float += product;
                        }
                        _ => panic!("mixed numeric kinds"),
                    }
                }
                let bits = if fmt.is_float() {
                    if float.is_nan() {
                        0x7fc0_0000
                    } else {
                        float.to_bits() as i32
                    }
                } else {
                    integer
                };
                out.push((ev.ptr_c + (i * ev.n as u64 + j) * 4, bits));
            }
        }
        out
    }

    fn random_case(fmt: NumFmt, m: u32, n: u32, k: u32, padding: u32) -> (PhysMem, AiTensorEvent) {
        let lda = k + padding;
        let ldb = k + padding + 1;
        let mut state = 0x1234_5678u32;
        let mut buffer = |len: u64| {
            let mut bytes = vec![0; len as usize];
            for byte in &mut bytes {
                state ^= state << 13;
                state ^= state >> 17;
                state ^= state << 5;
                *byte = state as u8;
            }
            bytes
        };
        let mut mem = PhysMem::new();
        mem.add(Region::from_file(
            BASE,
            &buffer(m as u64 * row_bytes(fmt, lda as u64)),
        ));
        mem.add(Region::from_file(
            BASE + 0x10_0000,
            &buffer(n as u64 * row_bytes(fmt, ldb as u64)),
        ));
        mem.add(Region::new(BASE + 0x20_0000, m as u64 * n as u64 * 4));
        let ev = AiTensorEvent {
            version: 1,
            op: 1,
            m,
            n,
            k,
            ld_ab: lda | (ldb << 16),
            flags: (fmt as u32) << 20,
            ptr_a: BASE,
            ptr_b: BASE + 0x10_0000,
            ptr_c: BASE + 0x20_0000,
            ..Default::default()
        };
        (mem, ev)
    }

    #[test]
    fn dma_destinations_reject_before_any_c_writes() {
        let (mut mem, original) = fixture();
        let mut model = model_granting(0xfb);
        model.desc_layout.statuses.insert("ST_BAD_PTR".into(), 0x55);
        for offset in 0..16 {
            mem.write_le::<1>(original.ptr_c + offset, 0xa5).unwrap();
        }
        for ptr in [
            original.ptr_c + 1,
            BASE + 0x2000,
            BASE + 0xff8,
            u64::MAX - 3,
        ] {
            let ev = AiTensorEvent {
                ptr_c: ptr,
                ..original
            };
            let result = execute(&mem, &ev, &model);
            assert_eq!(result.status, 0x55, "C={ptr:#x}");
            assert!(result.c_writes.is_empty());
        }
        for op in [1, 3] {
            for ptr in [BASE + 1, BASE + 0x2000, BASE + 0xffc, u64::MAX - 3] {
                let ev = AiTensorEvent {
                    op,
                    ptr_done: ptr,
                    ..original
                };
                let result = execute(&mem, &ev, &model);
                assert_eq!(result.status, 0x55, "done={ptr:#x}, op={op}");
                assert!(result.c_writes.is_empty());
            }
        }
        let saved = mem.snapshot();
        let mut overlay = PhysMem::new();
        overlay.add_device(crate::mem::Device::new(
            original.ptr_c + 7,
            1,
            crate::mem::DeviceKind::Uart(crate::device::Uart::default()),
        ));
        overlay.restore(&saved);
        let result = execute(&overlay, &original, &model);
        assert_eq!(result.status, 0x55);
        assert!(result.c_writes.is_empty());
        assert_eq!(overlay.snapshot(), saved);
        let mut ev = original;
        ev.ptr_c = BASE + 0x500;
        ev.ptr_done = original.ptr_c;
        assert_eq!(execute(&overlay, &ev, &model).status, 0x55);
        model.desc_layout.statuses.remove("ST_BAD_PTR");
        assert_eq!(execute(&overlay, &ev, &model).status, 1);
        ev.flags = 2 << 20;
        assert_eq!(execute(&overlay, &ev, &model).status, 8);
        ev.version = 2;
        assert_eq!(execute(&overlay, &ev, &model).status, 2);
        ev.version = original.version;
        ev.op = u16::MAX;
        assert_eq!(execute(&overlay, &ev, &model).status, 3);
        ev.op = original.op;
        ev.flags = 0;
        ev.m = 0;
        assert_eq!(execute(&overlay, &ev, &model).status, 1);
        for offset in 0..16 {
            assert_eq!(mem.read_le::<1>(original.ptr_c + offset).unwrap(), 0xa5);
        }
    }

    #[test]
    fn restored_input_device_overlay_is_not_a_ram_reuse_candidate() {
        let (mem, ev) = fixture();
        let mut overlay = PhysMem::new();
        overlay.add_device(crate::mem::Device::new(
            ev.ptr_a + 1,
            1,
            crate::mem::DeviceKind::Uart(crate::device::Uart::default()),
        ));
        overlay.restore(&mem.snapshot());
        assert!(!overlay.is_ram_range(ev.ptr_a, 4));
        assert_eq!(
            plan(&overlay, &ev, &model_granting(0xfb)).unwrap().c_writes,
            scalar_baseline(&overlay, &ev, NumFmt::Int)
        );
    }

    #[test]
    fn decoded_ram_reuse_matches_scalar_random_formats_and_strides() {
        for code in [0, 1, 3, 4, 5, 6, 7] {
            let fmt = NumFmt::from_abi(code).unwrap();
            for (m, n, k) in [(1, 7, 3), (5, 2, 9), (3, 4, 5), (1, 1, 1)] {
                for padding in [0, 1, 4] {
                    let (mem, ev) = random_case(fmt, m, n, k, padding);
                    let baseline = scalar_baseline(&mem, &ev, fmt);
                    let optimized = plan(&mem, &ev, &model_granting(0xfb)).unwrap();
                    assert_eq!(
                        optimized.c_writes, baseline,
                        "{fmt:?} {m}x{n}x{k} pad {padding}"
                    );
                }
            }
        }
    }

    fn mode_flags(
        model: &AiIslandModel,
        fmt: u32,
        dtype: u32,
        acc: u32,
        ew: u32,
        sparse: u32,
    ) -> u32 {
        let fl = model.desc_layout.flags_layout.unwrap();
        (fmt << fl.numfmt.unwrap().shift)
            | (dtype << fl.dtype_shift)
            | (acc << fl.accmode.unwrap().shift)
            | (ew << fl.ew.unwrap().shift)
            | (sparse << fl.sp24_bit.unwrap())
    }

    #[test]
    fn descriptor_modes_fail_closed_with_wide_grants() {
        let (mut mem, mut ev) = fixture();
        for offset in 0..16 {
            mem.write_le::<1>(ev.ptr_c + offset, 0xa5).unwrap();
        }
        for mask in [3, 0xfb, 0xff] {
            let model = model_granting(mask);
            for value in 1..4 {
                for (dtype, acc) in [(value, 0), (0, value)] {
                    ev.flags = mode_flags(&model, 0, dtype, acc, 0, 0);
                    let result = execute(&mem, &ev, &model);
                    assert_eq!(result.status, 8, "flags={:#x} mask={mask:#x}", ev.flags);
                    assert!(result.c_writes.is_empty());
                    for offset in 0..16 {
                        assert_eq!(mem.read_le::<1>(ev.ptr_c + offset).unwrap(), 0xa5);
                    }
                }
            }
        }
    }

    #[test]
    fn descriptor_modes_exhaustive_relocated_model() {
        let (mem, mut ev) = fixture();
        for relocated in [false, true] {
            let mut count = 0;
            for mask in [1, 3, 0xfb] {
                let mut model = model_granting(mask);
                if relocated {
                    let fl = model.desc_layout.flags_layout.as_mut().unwrap();
                    fl.dtype_shift = 0;
                    fl.accmode.as_mut().unwrap().shift = 3;
                    fl.ew.as_mut().unwrap().shift = 6;
                    fl.sp24_bit = Some(9);
                    fl.numfmt.as_mut().unwrap().shift = 25;
                }
                for fmt in 0..8 {
                    for dtype in 0..4 {
                        for acc in 0..4 {
                            for ew in 0..4 {
                                for sparse in 0..2 {
                                    ev.flags = mode_flags(&model, fmt, dtype, acc, ew, sparse);
                                    let effective = if fmt == 0 && ew == 1 { 1 } else { fmt };
                                    let legal = dtype == 0
                                        && acc == 0
                                        && sparse == 0
                                        && fmt != 2
                                        && ew < 2
                                        && (fmt < 3 || ew == 0)
                                        && mask & (1 << effective) != 0;
                                    let result = plan(&mem, &ev, &model);
                                    assert_eq!(
                                        result.is_ok(),
                                        legal,
                                        "relocated={relocated} flags={:#x} mask={mask:#x}",
                                        ev.flags
                                    );
                                    if legal {
                                        assert_eq!(
                                            resolve_numfmt(&model, ev.flags).unwrap(),
                                            NumFmt::from_abi(effective).unwrap()
                                        );
                                    } else {
                                        assert_eq!(
                                            result.unwrap_err(),
                                            (AiJobReject::UngrantedDtype, 8)
                                        );
                                        assert!(execute(&mem, &ev, &model).c_writes.is_empty());
                                    }
                                    count += 1;
                                }
                            }
                        }
                    }
                }
            }
            assert_eq!(count, 3072);
        }
    }

    #[test]
    fn unresolved_legacy_layout_retains_compatibility() {
        let (mem, mut ev) = fixture();
        let mut model = model_granting(1);
        ev.flags = mode_flags(&model, 0, 0, 0, 1, 0);
        model.desc_layout.flags_layout.as_mut().unwrap().numfmt = None;
        assert_eq!(execute(&mem, &ev, &model).status, 8);
        model.config.dtype_mask = Some(3);
        assert_eq!(resolve_numfmt(&model, ev.flags), Ok(NumFmt::Int));
        assert_eq!(execute(&mem, &ev, &model).status, 0);
        model.desc_layout.flags_layout = None;
        assert_eq!(execute(&mem, &ev, &model).status, 0);
    }

    #[test]
    fn descriptor_int4_aliases_compute_odd_k_padded_rows() {
        let (mut mem, mut ev) = fixture();
        ev.k = 3;
        ev.ld_ab = 5 | (5 << 16);
        for (base, bytes) in [
            (ev.ptr_a, [0x2f, 0xe3, 0xab, 0xb4, 0xe6, 0xcd]),
            (ev.ptr_b, [0xd2, 0xe4, 0xab, 0x2f, 0xee, 0xcd]),
        ] {
            for (offset, byte) in bytes.iter().enumerate() {
                mem.write_le::<1>(base + offset as u64, *byte as u64)
                    .unwrap();
            }
        }
        for (fmt, ew) in [(0, 1), (1, 0), (1, 1)] {
            for mask in [3, 1, 2, 0xf9, 0xfb, 0xff] {
                let model = model_granting(mask);
                ev.flags = mode_flags(&model, fmt, 0, 0, ew, 0);
                let result = execute(&mem, &ev, &model);
                if mask & (1 << NumFmt::Int4.grant_bit()) == 0 {
                    assert_eq!(result.status, 8);
                    assert!(result.c_writes.is_empty());
                } else {
                    assert_eq!(result.status, 0);
                    assert_eq!(
                        result.c_writes.iter().map(|(_, v)| *v).collect::<Vec<_>>(),
                        [4, -1, 47, -26]
                    );
                }
            }
        }
    }

    #[test]
    fn sparse_is_never_dense_even_if_granted() {
        let (mem, mut ev) = fixture();
        let model = model_granting(0xff);
        for flags in [2 << 20, 1 << 14] {
            ev.flags = flags;
            assert_eq!(
                plan(&mem, &ev, &model),
                Err((AiJobReject::UngrantedDtype, 8))
            );
            assert!(execute(&mem, &ev, &model).c_writes.is_empty());
        }
    }

    #[test]
    fn wrapping_pointers_and_late_input_faults_produce_no_writes() {
        let (mem, mut ev) = fixture();
        let model = model_granting(0xfb);
        ev.ptr_a = u64::MAX;
        assert!(execute(&mem, &ev, &model).c_writes.is_empty());
        ev.ptr_a = BASE + 0xffd;
        assert!(execute(&mem, &ev, &model).c_writes.is_empty());
        ev.ptr_a = BASE + 0x100;
        ev.ptr_c = u64::MAX - 3;
        assert!(execute(&mem, &ev, &model).c_writes.is_empty());
    }

    #[test]
    fn mmio_uses_scalar_fallback() {
        use crate::mem::{Device, DeviceKind};
        let (mut mem, mut ev) = fixture();
        mem.add_device(Device::new(
            BASE + 0x2000,
            8,
            DeviceKind::Uart(crate::device::Uart::default()),
        ));
        ev.ptr_a = BASE + 0x2000;
        assert!(!mem.is_ram_range(ev.ptr_a, 4));
        assert_eq!(
            plan(&mem, &ev, &model_granting(0xfb)).unwrap().c_writes,
            scalar_baseline(&mem, &ev, NumFmt::Int)
        );
    }

    #[test]
    fn float_specials_and_nonfused_rounding() {
        let mut mem = PhysMem::new();
        let x = f32::from_bits(0x3f80_0001);
        let y = f32::from_bits(0x3f7f_fffe);
        let a: Vec<u8> = [-1f32, x].iter().flat_map(|v| v.to_le_bytes()).collect();
        let b: Vec<u8> = [1f32, y].iter().flat_map(|v| v.to_le_bytes()).collect();
        mem.add(Region::from_file(BASE, &a));
        mem.add(Region::from_file(BASE + 64, &b));
        mem.add(Region::new(BASE + 128, 4));
        let mut ev = AiTensorEvent {
            version: 1,
            op: 1,
            m: 1,
            n: 1,
            k: 2,
            ld_ab: 2 | (2 << 16),
            flags: 7 << 20,
            ptr_a: BASE,
            ptr_b: BASE + 64,
            ptr_c: BASE + 128,
            ..Default::default()
        };
        let model = model_granting(0xfb);
        assert_ne!(x.mul_add(y, -1.0).to_bits(), 0);
        assert_eq!(plan(&mem, &ev, &model).unwrap().c_writes[0].1, 0);
        ev.k = 1;
        for bits in [
            0x7f80_0001u32,
            0xffc1_2345,
            0x8000_0000,
            1,
            0x7f80_0000,
            0xff80_0000,
        ] {
            mem.write_le::<4>(BASE, bits as u64).unwrap();
            let result = plan(&mem, &ev, &model).unwrap();
            assert_eq!(result.c_writes, scalar_baseline(&mem, &ev, NumFmt::Fp32));
            if f32::from_bits(bits).is_nan() {
                assert_eq!(result.c_writes[0].1, 0x7fc0_0000);
            }
        }
    }

    #[test]
    #[ignore = "host-only wall-clock benchmark; not RTL timing"]
    fn host_decode_reuse_benchmark() {
        use std::hint::black_box;
        use std::time::Instant;
        for code in [0, 1, 3, 4, 5, 6, 7] {
            let fmt = NumFmt::from_abi(code).unwrap();
            let (mem, ev) = random_case(fmt, 64, 48, 128, 3);
            let model = model_granting(0xfb);
            assert_eq!(
                plan(&mem, &ev, &model).unwrap().c_writes,
                scalar_baseline(&mem, &ev, fmt)
            );
            let start = Instant::now();
            for _ in 0..10 {
                black_box(scalar_baseline(black_box(&mem), black_box(&ev), fmt));
            }
            let baseline = start.elapsed();
            let start = Instant::now();
            for _ in 0..10 {
                black_box(plan(black_box(&mem), black_box(&ev), black_box(&model)).unwrap());
            }
            let optimized = start.elapsed();
            println!(
                "HOST ONLY {fmt:?} 64x48x128 x10 baseline_us={} optimized_us={} speedup={:.2}",
                baseline.as_micros(),
                optimized.as_micros(),
                baseline.as_secs_f64() / optimized.as_secs_f64()
            );
        }
    }

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
        // This helper is the functional model: a granted float is executed.
        // The synthesizable strip leaves `fp_datapath` false.
        m.config.fp_datapath = true;
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
        assert_eq!(
            NumFmt::Fp32.status_for_mask(1, false),
            st,
            "the emulator status and the grant helper stay the same code"
        );
    }

    /// A fast mask without a float datapath does not multiply FP32.
    #[test]
    fn a_float_grant_without_a_datapath_is_refused() {
        let (mem, ev) = fixture_fmt(NumFmt::Fp32);
        let mut m = model_granting(0xfb);
        m.config.fp_datapath = false;
        let (why, st) = plan(&mem, &ev, &m).expect_err("mask bit is not a datapath");
        assert_eq!(why, AiJobReject::UngrantedDtype);
        assert_eq!(st, NumFmt::Fp32.status_for_mask(0xfb, false));
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
    fn a_reuse_hit_keeps_the_resident_byte_until_the_epoch_changes() {
        let mut mem = PhysMem::new();
        mem.add(Region::new(BASE, 0x1000));
        mem.write_le::<1>(BASE + 0x100, 1).unwrap();
        mem.write_le::<1>(BASE + 0x200, 2).unwrap();
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
        let m = model(256);
        let mut cache = OperandReuse::default();
        let off = super::plan_with(&mem, &ev, &m, Some(&cache)).unwrap();
        assert_eq!(off.c_writes, vec![(BASE + 0x300, 2)]);
        assert!(off.read_b);
        cache.set_enabled(true);
        let primed = super::plan_with(&mem, &ev, &m, Some(&cache)).unwrap();
        cache.observe(primed.read_a, primed.read_b);
        cache.commit(&primed);
        mem.write_le::<1>(BASE + 0x200, 9).unwrap();
        let mut hit = ev;
        hit.flags = super::FLAG_REUSE_B;
        let stayed = super::plan_with(&mem, &hit, &m, Some(&cache)).unwrap();
        assert_eq!(stayed.c_writes, vec![(BASE + 0x300, 2)]);
        assert!(!stayed.read_b);
        cache.commit(&stayed);
        cache.epoch = 1;
        let missed = super::plan_with(&mem, &hit, &m, Some(&cache)).unwrap();
        assert_eq!(missed.c_writes, vec![(BASE + 0x300, 9)]);
        assert!(missed.read_b);
        cache.commit(&missed);
        let mut overlap = hit;
        overlap.ptr_c = overlap.ptr_b;
        mem.write_le::<1>(BASE + 0x200, 4).unwrap();
        let dropped = super::plan_with(&mem, &overlap, &m, Some(&cache)).unwrap();
        assert_eq!(dropped.c_writes, vec![(overlap.ptr_c, 4)]);
        assert!(dropped.read_b);
        cache.commit(&dropped);
        let mut again = hit;
        again.ptr_c = BASE + 0x300;
        let reloaded = super::plan_with(&mem, &again, &m, Some(&cache)).unwrap();
        assert!(reloaded.read_b, "C on B drops the key");
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

    fn directed_model() -> AiIslandModel {
        let mut model = model(16);
        model.config.acc_tile_m = 1024;
        model.config.acc_tile_n = 512;
        model.config.acc_tile_k = 16;
        model.config.macs_per_cycle = super::VA_TURBO_TEST_MACS;
        model
    }

    fn ones(mem: &mut PhysMem, ptr: u64, len: u64) {
        for i in 0..len {
            mem.write_le::<1>(ptr + i, 1).unwrap();
        }
    }

    fn schedule(
        model: &AiIslandModel,
        m: u32,
        n: u32,
        k: u32,
    ) -> Result<VaTurboTestRun, &'static str> {
        let mut mem = PhysMem::new();
        mem.add(Region::new(BASE, 0x1000));
        let ptr_a = BASE;
        let ptr_b = BASE + 0x400;
        let ptr_c = BASE + 0x800;
        ones(&mut mem, ptr_a, u64::from(m) * u64::from(k));
        ones(&mut mem, ptr_b, u64::from(n) * u64::from(k));
        run_va_turbo_test_s8(model, &mem, m, n, k, ptr_a, ptr_b, ptr_c)
    }

    #[test]
    fn the_qemu_schedule_enables_reuse_only_when_a_tile_skips() {
        let mut live = model(512);
        live.config.acc_tile_m = 1024;
        live.config.acc_tile_n = 512;
        live.config.acc_tile_k = 512;
        live.config.macs_per_cycle = 512;
        assert!(!directed_va_turbo_model(&live));
        assert!(schedule(&live, 16, 8, 8).is_err());

        let directed = directed_model();
        assert!(directed_va_turbo_model(&directed));
        let m_split = schedule(&directed, 16, 8, 8).unwrap();
        assert_eq!(m_split.flags.len(), 2);
        assert_eq!(m_split.flags[1] & super::FLAG_REUSE_B, super::FLAG_REUSE_B);
        assert_eq!(m_split.flags[1] & super::FLAG_REUSE_A, 0);
        assert!(m_split.read_a);
        assert!(!m_split.read_b);
        assert!(m_split.hit_b);
        assert!(!m_split.hit_a);
        assert!(m_split.reuse_enabled);
        assert_eq!(m_split.c, vec![8i32; 16 * 8]);

        let k_split = schedule(&directed, 8, 8, 16).unwrap();
        assert_eq!(k_split.flags.len(), 2);
        assert_eq!(
            k_split.flags[1] & (super::FLAG_REUSE_A | super::FLAG_REUSE_B),
            0
        );
        assert!(k_split.read_a);
        assert!(k_split.read_b);
        assert!(!k_split.hit_a);
        assert!(!k_split.hit_b);
        assert!(!k_split.reuse_enabled);
        assert_eq!(k_split.c, vec![16i32; 8 * 8]);

        let n_split = schedule(&directed, 8, 16, 8).unwrap();
        assert_eq!(n_split.flags[1] & super::FLAG_REUSE_A, super::FLAG_REUSE_A);
        assert_eq!(n_split.flags[1] & super::FLAG_REUSE_B, 0);
        assert!(!n_split.read_a);
        assert!(n_split.read_b);
        assert!(n_split.hit_a);
        assert!(!n_split.hit_b);
        assert!(n_split.reuse_enabled);
        assert_eq!(n_split.c, vec![8i32; 8 * 16]);
    }
}
