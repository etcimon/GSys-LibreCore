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
    /// Lower to a single Desc64. Fails if dims exceed `tile` (default island_p3 512).
    pub fn lower(&self) -> Result<Desc64, IrError> {
        self.lower_with_tile(AccTile::ISLAND_P3_DEFAULT)
    }

    pub fn lower_with_tile(&self, tile: AccTile) -> Result<Desc64, IrError> {
        if self.m == 0 || self.n == 0 || self.k == 0 || self.k > 0xffff {
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
        d.ld_ab = self.k | (self.k << 16);
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

/// The three output shapes whose reuse keys stay distinct at this MAC issue
/// width: `macs×macs`, `macs×macs/2`, and `(2·macs)×macs/4`, each with K
/// `≤ macs`. A width that is not a multiple of 4 has no such set.
pub fn va_panels(macs: u32) -> Vec<AccTile> {
    if macs < 4 || macs % 4 != 0 {
        return Vec::new();
    }
    let half = macs / 2;
    let quarter = macs / 4;
    vec![
        AccTile {
            m: macs,
            n: macs,
            k: macs,
        },
        AccTile {
            m: macs,
            n: half,
            k: macs,
        },
        AccTile {
            m: macs.saturating_mul(2),
            n: quarter,
            k: macs,
        },
    ]
}

fn div_ceil_u64(n: u32, d: u32) -> Option<u64> {
    if d == 0 {
        return None;
    }
    Some(u64::from(n).div_ceil(u64::from(d)))
}

/// Blocking tile for a VA-panel schedule.
///
/// Among the named panels that fit inside `cap`, pick the one with the fewest
/// descriptors, then the most descriptors whose M×N is exactly that panel,
/// then the wider N (so a later M tile can reuse B). A cap the panels do not
/// fit returns `cap` unchanged, so a smaller device is not asked for a panel
/// it will refuse.
pub fn va_blocking_tile(m: u32, n: u32, k: u32, cap: AccTile, macs: u32) -> AccTile {
    let mut best: Option<(u64, u64, u32, AccTile)> = None;
    for panel in va_panels(macs) {
        if panel.m == 0
            || panel.n == 0
            || panel.k == 0
            || panel.m > cap.m
            || panel.n > cap.n
            || panel.k > cap.k
        {
            continue;
        }
        let (Some(tm), Some(tn), Some(tk)) = (
            div_ceil_u64(m, panel.m),
            div_ceil_u64(n, panel.n),
            div_ceil_u64(k, panel.k),
        ) else {
            continue;
        };
        let Some(tiles) = tm.checked_mul(tn).and_then(|x| x.checked_mul(tk)) else {
            continue;
        };
        let exact_m = if panel.m != 0 && m % panel.m == 0 {
            tm
        } else {
            tm.saturating_sub(1)
        };
        let exact_n = if panel.n != 0 && n % panel.n == 0 {
            tn
        } else {
            tn.saturating_sub(1)
        };
        let named = exact_m.saturating_mul(exact_n).saturating_mul(tk);
        let replace = match best {
            None => true,
            Some((bt, bn, bw, _)) => {
                tiles < bt || (tiles == bt && (named > bn || (named == bn && panel.n > bw)))
            }
        };
        if replace {
            best = Some((tiles, named, panel.n, panel));
        }
    }
    best.map(|(_, _, _, panel)| panel).unwrap_or(cap)
}

/// Highest `va_turbo_level`. The field is four bits.
pub const VA_TURBO_LEVEL_MAX: u32 = 15;
/// Saturation of the geometric ppm ladder (100%).
pub const VA_TURBO_PPM_SAT: u32 = 1_000_000;

/// Geometric error budget. Level 0 is 0 ppm. Level 1 is 100 ppm and each
/// later step doubles, saturating at [`VA_TURBO_PPM_SAT`]. A level above 15
/// is not on the ladder.
pub fn va_turbo_budget_ppm(level: u32) -> Option<u32> {
    if level == 0 {
        Some(0)
    } else if level <= VA_TURBO_LEVEL_MAX {
        Some((100u32 << (level - 1)).min(VA_TURBO_PPM_SAT))
    } else {
        None
    }
}

/// Round `ppm` up to a ladder index. A bound above 100% is `None`: it is not
/// saturated into level 15.
pub fn va_turbo_error_bound_q4(ppm: u32) -> Option<u32> {
    if ppm > VA_TURBO_PPM_SAT {
        return None;
    }
    if ppm == 0 {
        return Some(0);
    }
    for level in 1..=VA_TURBO_LEVEL_MAX {
        if va_turbo_budget_ppm(level).unwrap_or(0) >= ppm {
            return Some(level);
        }
    }
    None
}

/// `level` is inside the caller's ppm budget. This does not change a product.
pub fn va_turbo_level_within_bound(level: u32, caller_ppm: u32) -> bool {
    match (va_turbo_budget_ppm(level), va_turbo_error_bound_q4(caller_ppm)) {
        (Some(_), Some(bound)) => level <= bound,
        _ => false,
    }
}

/// `(eps_ppm * kappa_q8 + 255) >> 8`, with `kappa_q8 = kappa * 256`.
/// `kappa_q8 < 256` is kappa below 1 and fails closed. A composed bound above
/// 100% fails closed. This does not change a product.
pub fn va_turbo_compose_ppm(eps_ppm: u32, kappa_q8: u32) -> Option<u32> {
    if kappa_q8 < 256 {
        return None;
    }
    let composed = (u64::from(eps_ppm) * u64::from(kappa_q8) + 255) >> 8;
    if composed > u64::from(VA_TURBO_PPM_SAT) {
        return None;
    }
    Some(composed as u32)
}

/// The analytic bound and the caller's bound both fit `level`. Level 0 is the
/// only level the MAC path applies.
pub fn va_turbo_recipe_admitted(
    level: u32,
    eps_ppm: u32,
    kappa_q8: u32,
    caller_ppm: u32,
) -> bool {
    let Some(budget) = va_turbo_budget_ppm(level) else {
        return false;
    };
    let Some(composed) = va_turbo_compose_ppm(eps_ppm, kappa_q8) else {
        return false;
    };
    composed <= budget && va_turbo_level_within_bound(level, caller_ppm)
}

/// Untightened quantisation flatness, `fa + fb = 2` in Q8. The selector uses
/// this whenever the caller cannot prove a tighter value.
pub const VA_TURBO_FLAT_WORST_Q8: u32 = 512;

/// Relative ppm for a product of two round-to-nearest mantissas of `bits`.
pub fn va_turbo_round_eps_ppm(bits: u32) -> Option<u32> {
    const TABLE: [Option<u32>; 24] = [
        None,
        Some(562_500),
        Some(265_625),
        Some(128_907),
        Some(63_477),
        Some(31_495),
        Some(15_687),
        Some(7_828),
        Some(3_911),
        Some(1_955),
        Some(977),
        Some(489),
        Some(245),
        Some(123),
        Some(62),
        Some(31),
        Some(16),
        Some(8),
        Some(4),
        Some(2),
        Some(1),
        Some(1),
        Some(1),
        Some(1),
    ];
    TABLE.get(bits as usize).copied().flatten()
}

/// Relative ppm for a product of two truncated mantissas of `bits`.
pub fn va_turbo_trunc_eps_ppm(bits: u32) -> Option<u32> {
    const TABLE: [Option<u32>; 24] = [
        Some(1_000_000),
        Some(750_000),
        Some(437_500),
        Some(234_375),
        Some(121_094),
        Some(61_524),
        Some(31_006),
        Some(15_564),
        Some(7_798),
        Some(3_903),
        Some(1_953),
        Some(977),
        Some(489),
        Some(245),
        Some(123),
        Some(62),
        Some(31),
        Some(16),
        Some(8),
        Some(4),
        Some(2),
        Some(1),
        Some(1),
        Some(1),
    ];
    TABLE.get(bits as usize).copied().flatten()
}

/// Full-scale quantisation ppm. `flat_q8` above 512 is looser than the
/// worst case and fails closed. `0` means the worst case, 512.
pub fn va_turbo_quant_eps_ppm(levels: u32, flat_q8: u32) -> Option<u32> {
    let flat = if flat_q8 == 0 { VA_TURBO_FLAT_WORST_Q8 } else { flat_q8 };
    if flat > VA_TURBO_FLAT_WORST_Q8 {
        return None;
    }
    let (per_unit, constant_term) = match levels {
        127 => (3_938u32, 16u32),
        7 => (71_429u32, 5_103u32),
        _ => return None,
    };
    let scaled = (u64::from(per_unit) * u64::from(flat) + 255) >> 8;
    let total = scaled + u64::from(constant_term);
    if total > u64::from(VA_TURBO_PPM_SAT) {
        None
    } else {
        Some(total as u32)
    }
}

/// Per-recipe analytic epsilon from `va_turbo_arith`.
///
/// Exact ids are 0. Recipe 26 is the unspecified sentinel and returns
/// `None`. A recipe that needs `approx_param` returns `None` without one.
/// Absent flatness uses [`VA_TURBO_FLAT_WORST_Q8`].
pub fn va_turbo_recipe_eps_ppm(
    id: u32,
    approx_param: Option<u32>,
    flat_q8: Option<u32>,
) -> Option<u32> {
    let flat = match flat_q8 {
        None | Some(0) => VA_TURBO_FLAT_WORST_Q8,
        Some(value) => value,
    };
    match id {
        0 | 1 | 2 | 3 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 22 | 23 | 24 => {
            Some(0)
        }
        4 => va_turbo_round_eps_ppm(10),
        5 => va_turbo_round_eps_ppm(7),
        6 => va_turbo_quant_eps_ppm(127, flat),
        7 => va_turbo_round_eps_ppm(3),
        18 => match approx_param? & 3 {
            0 => va_turbo_round_eps_ppm(10),
            1 => va_turbo_round_eps_ppm(7),
            2 => va_turbo_quant_eps_ppm(127, flat),
            _ => va_turbo_round_eps_ppm(2),
        },
        19 | 20 => va_turbo_quant_eps_ppm(127, flat),
        21 | 25 | 30 | 31 => va_turbo_trunc_eps_ppm(approx_param?),
        26 => None,
        27 | 28 => Some(250_000),
        29 => va_turbo_quant_eps_ppm(7, flat),
        _ => None,
    }
}

/// Arithmetic class of one recipe id, matching `va_turbo_arith`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VaArithKind {
    Exact,
    Rel,
    Full,
    None,
}

/// One bank entry. The action fields stay clear.
///
/// `supported` means the id has an arithmetic class. It does not mean the
/// selector may apply the entry. `apply`, reuse, convert, and the other
/// action fields are false for every id.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VaTurboDecode {
    pub kind: VaArithKind,
    pub eps_ppm: Option<u32>,
    pub needs_param: bool,
    pub narrows_storage: bool,
    pub quant_levels: Option<u8>,
    pub supported: bool,
    pub apply: bool,
    pub reuse_a: bool,
    pub reuse_b: bool,
    pub convert: bool,
    pub approx_products: bool,
    pub skip_products: bool,
    pub split_rows: bool,
    pub groups_log2: u8,
    pub rewrites_format: bool,
}

impl VaTurboDecode {
    const fn idle() -> Self {
        Self {
            kind: VaArithKind::None,
            eps_ppm: None,
            needs_param: false,
            narrows_storage: false,
            quant_levels: None,
            supported: false,
            apply: false,
            reuse_a: false,
            reuse_b: false,
            convert: false,
            approx_products: false,
            skip_products: false,
            split_rows: false,
            groups_log2: 0,
            rewrites_format: false,
        }
    }

    #[cfg(test)]
    fn actions_clear(self) -> bool {
        !self.apply
            && !self.reuse_a
            && !self.reuse_b
            && !self.convert
            && !self.approx_products
            && !self.skip_products
            && !self.split_rows
            && self.groups_log2 == 0
            && !self.rewrites_format
    }
}

/// Shape class from `policy_encode`, for a plain GEMM with no opcode.
pub const POLICY_BULK: u8 = 0;
pub const POLICY_WIDE: u8 = 1;
pub const POLICY_TALL: u8 = 2;
pub const POLICY_DECODE: u8 = 3;
pub const POLICY_MOVEMENT: u8 = 7;

/// Automatic exact choice for one shape. Approximate ids stay withheld.
///
/// A decode shape (`m <= 1`, `n >= 2`, `k >= 2`) selects resident B, recipe
/// 16. The transposed shape (`n <= 1`, `m >= 2`, `k >= 2`) selects resident
/// A, the same recipe. The two are never both set. `large_decode` is B's
/// share of reads at least 99%. `large_resident` is the selected operand's
/// share at that same line. This record does not apply a recipe and does
/// not enable reuse on a device. `withheld` is every non-exact id.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WorkloadChoice {
    pub code: u8,
    pub exact_recipe: Option<u32>,
    pub reuse_b: bool,
    pub reuse_a: bool,
    pub apply: bool,
    pub large_decode: bool,
    pub large_resident: bool,
    pub b_share_millis: u32,
    pub a_share_millis: u32,
    pub withheld: u32,
}

/// Choose the exact optimization for a shape. `apply` stays false.
pub fn select_workload(m: u32, n: u32, k: u32) -> WorkloadChoice {
    let code = if m == 0 || n == 0 || k == 0 {
        POLICY_MOVEMENT
    } else if m <= 1 && n >= 2 && k >= 2 {
        POLICY_DECODE
    } else if n > m {
        POLICY_WIDE
    } else if m > n {
        POLICY_TALL
    } else {
        POLICY_BULK
    };
    let denom = m.saturating_add(n);
    let b_share_millis = if denom == 0 { 0 } else { n.saturating_mul(1000) / denom };
    let a_share_millis = if denom == 0 { 0 } else { m.saturating_mul(1000) / denom };
    let reuse_b = code == POLICY_DECODE;
    let reuse_a = code == POLICY_TALL && n <= 1 && m >= 2 && k >= 2;
    let withheld = (0..=31u32)
        .filter(|id| va_turbo_decode(*id, None, None).kind != VaArithKind::Exact)
        .count() as u32;
    WorkloadChoice {
        code,
        exact_recipe: if reuse_a || reuse_b { Some(16) } else { None },
        reuse_b,
        reuse_a,
        apply: false,
        large_decode: reuse_b && b_share_millis >= 990,
        large_resident: (reuse_b && b_share_millis >= 990) || (reuse_a && a_share_millis >= 990),
        b_share_millis,
        a_share_millis,
        withheld,
    }
}

/// Ids from the withheld set that pass permission and the analytic bound.
///
/// `apply` stays false. Listing an id does not arm an evidence window and
/// does not change a product. Exact ids are not in this set.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WithheldAdmission {
    pub ids: Vec<u32>,
    pub apply: bool,
}

/// Consider withheld recipes. An id is listed only when `permitted` is true
/// and [`va_turbo_recipe_claim_fits`] accepts it.
pub fn admit_withheld(
    gates: VaTurboGates,
    level: u32,
    measured_ppm: Option<u32>,
    kappa_q8: Option<u32>,
    consumer_mask: u32,
    profile_mask: u32,
    window_valid: bool,
    approx_param: Option<u32>,
) -> WithheldAdmission {
    let mut ids = Vec::new();
    for id in 0..=31u32 {
        if va_turbo_decode(id, approx_param, None).kind == VaArithKind::Exact {
            continue;
        }
        let permitted = va_turbo_permission(
            gates,
            level,
            id,
            consumer_mask,
            profile_mask,
            window_valid,
        )
        .permitted;
        if permitted
            && va_turbo_recipe_claim_fits(level, id, measured_ppm, kappa_q8, approx_param)
        {
            ids.push(id);
        }
    }
    WithheldAdmission { ids, apply: false }
}

/// Decode one recipe id. An id above 31 is unsupported and still has no actions.
pub fn va_turbo_decode(
    id: u32,
    approx_param: Option<u32>,
    flat_q8: Option<u32>,
) -> VaTurboDecode {
    let (kind, needs_param, narrows_storage, quant_levels) = match id {
        0..=3 | 8..=17 | 22 | 23 | 24 => (VaArithKind::Exact, false, false, None),
        4 | 5 | 7 => (VaArithKind::Rel, false, true, None),
        6 => (VaArithKind::Full, false, true, Some(127)),
        18 => (
            VaArithKind::Rel,
            true,
            true,
            if approx_param.map(|param| param & 3 == 2).unwrap_or(false) {
                Some(127)
            } else {
                None
            },
        ),
        19 => (VaArithKind::Full, false, false, Some(127)),
        20 => (VaArithKind::Full, false, true, Some(127)),
        21 | 25 | 30 | 31 => (VaArithKind::Rel, true, false, None),
        26 => (VaArithKind::Rel, true, false, None),
        27 | 28 => (VaArithKind::Rel, false, false, None),
        29 => (VaArithKind::Full, false, true, Some(7)),
        _ => return VaTurboDecode::idle(),
    };
    VaTurboDecode {
        kind,
        eps_ppm: va_turbo_recipe_eps_ppm(id, approx_param, flat_q8),
        needs_param,
        narrows_storage,
        quant_levels,
        supported: true,
        apply: false,
        reuse_a: false,
        reuse_b: false,
        convert: false,
        approx_products: false,
        skip_products: false,
        split_rows: false,
        groups_log2: 0,
        rewrites_format: false,
    }
}

/// The four promotion gates. All four have to be present, or promotion stays off.
///
/// The documented 18,527 ppm tile figure is not one of these gates.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct PromotionGates {
    pub concurrency_measured: bool,
    pub held_out_pair: bool,
    pub gain_threshold_recorded: bool,
    pub beyond_tile_proxy: bool,
}

impl PromotionGates {
    pub const fn ready(self) -> bool {
        self.concurrency_measured
            && self.held_out_pair
            && self.gain_threshold_recorded
            && self.beyond_tile_proxy
    }
}

/// Live `g6lc64` bit. A ready gate set does not write it.
pub const LIVE_VA_TURBO_EN: bool = false;

/// Host decision for the live bit. Exact reuse matching the reference is
/// necessary, and so are all four promotion gates. This does not write
/// [`LIVE_VA_TURBO_EN`].
pub fn va_turbo_en_allowed(exact_reuse_ok: bool, gates: PromotionGates) -> bool {
    let _ = (exact_reuse_ok, gates);
    false
}

/// The four promotion gates, in the order a decision lists them.
pub const PROMOTION_GATES: &[&str] = &[
    "concurrency_measured",
    "held_out_pair",
    "gain_threshold_recorded",
    "beyond_tile_proxy",
];

/// What still blocks the live bit. `allowed` does not write it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VaTurboDecision {
    pub exact_reuse_ok: bool,
    pub allowed: bool,
    pub missing: Vec<&'static str>,
}

/// Name every missing requirement. An empty list is the only allow.
pub fn va_turbo_decision(exact_reuse_ok: bool, gates: PromotionGates) -> VaTurboDecision {
    let mut missing = Vec::new();
    if !exact_reuse_ok {
        missing.push("exact_reuse");
    }
    if !gates.concurrency_measured {
        missing.push("concurrency_measured");
    }
    if !gates.held_out_pair {
        missing.push("held_out_pair");
    }
    if !gates.gain_threshold_recorded {
        missing.push("gain_threshold_recorded");
    }
    if !gates.beyond_tile_proxy {
        missing.push("beyond_tile_proxy");
    }
    VaTurboDecision {
        exact_reuse_ok,
        allowed: false,
        missing,
    }
}

/// One measured requirement. `status` is `passed`, `failed`, or `absent`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GateWitness {
    pub name: &'static str,
    pub status: &'static str,
    pub source: &'static str,
}

/// Lane groups were measured and do not add MAC/s. The other gates have
/// no measurement.
pub fn known_promotion_witnesses() -> [GateWitness; 4] {
    [
        GateWitness {
            name: "concurrency_measured",
            status: "failed",
            source: "lane-groups",
        },
        GateWitness {
            name: "held_out_pair",
            status: "absent",
            source: "",
        },
        GateWitness {
            name: "gain_threshold_recorded",
            status: "absent",
            source: "",
        },
        GateWitness {
            name: "beyond_tile_proxy",
            status: "absent",
            source: "",
        },
    ]
}

/// A passed witness needs a source. Lane groups cannot pass concurrency.
/// The random BERT layer cannot pass beyond-tile accuracy.
pub fn accept_witness(proposed: GateWitness) -> GateWitness {
    let status = if proposed.status != "passed"
        && proposed.status != "failed"
        && proposed.status != "absent"
    {
        "absent"
    } else if proposed.status == "passed" && proposed.source.is_empty() {
        "absent"
    } else if proposed.name == "concurrency_measured"
        && proposed.status == "passed"
        && proposed.source == "lane-groups"
    {
        "failed"
    } else if proposed.name == "beyond_tile_proxy"
        && proposed.status == "passed"
        && proposed.source == "huggingface-bert-random"
    {
        "absent"
    } else {
        proposed.status
    };
    GateWitness {
        name: proposed.name,
        status,
        source: proposed.source,
    }
}

/// Allow only when exact reuse and every gate witness passed.
/// This does not write [`LIVE_VA_TURBO_EN`].
pub fn va_turbo_from_witnesses(exact: GateWitness, gates: &[GateWitness]) -> VaTurboDecision {
    let exact = accept_witness(exact);
    let exact_ok = exact.name == "exact_reuse" && exact.status == "passed";
    let mut missing = Vec::new();
    if !exact_ok {
        missing.push("exact_reuse");
    }
    let accepted: Vec<GateWitness> = gates.iter().copied().map(accept_witness).collect();
    for name in PROMOTION_GATES {
        let status = accepted
            .iter()
            .find(|gate| gate.name == *name)
            .map(|gate| gate.status)
            .unwrap_or("absent");
        if status != "passed" {
            missing.push(match status {
                "failed" => match *name {
                    "concurrency_measured" => "concurrency_measured:failed",
                    "held_out_pair" => "held_out_pair:failed",
                    "gain_threshold_recorded" => "gain_threshold_recorded:failed",
                    "beyond_tile_proxy" => "beyond_tile_proxy:failed",
                    _ => "unknown:failed",
                },
                "absent" => match *name {
                    "concurrency_measured" => "concurrency_measured:absent",
                    "held_out_pair" => "held_out_pair:absent",
                    "gain_threshold_recorded" => "gain_threshold_recorded:absent",
                    "beyond_tile_proxy" => "beyond_tile_proxy:absent",
                    _ => "unknown:absent",
                },
                _ => match *name {
                    "concurrency_measured" => "concurrency_measured:invalid",
                    "held_out_pair" => "held_out_pair:invalid",
                    "gain_threshold_recorded" => "gain_threshold_recorded:invalid",
                    "beyond_tile_proxy" => "beyond_tile_proxy:invalid",
                    _ => "unknown:invalid",
                },
            });
        }
    }
    let allowed = missing.is_empty();
    VaTurboDecision {
        exact_reuse_ok: exact_ok,
        allowed,
        missing,
    }
}

/// Section 11 items. Decode and admission do not select them.
pub const SECTION11_OPEN: &[&str] = &[
    "lane_groups",
    "float_reductions",
    "converters",
    "proof_producers",
    "approximate_consumers",
    "multi_cluster",
];

pub fn section11_selected() -> bool {
    false
}

/// Configurable fabric. The live setting is a 512-bit island DMA on a
/// 64-bit fabric and is not promoted. A legal wider fabric is.
///
/// Legal widths are powers of two from 64 through 4096. Anything else
/// carries 0 bytes/cycle.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PortSetting {
    pub island_bits: u32,
    pub fabric_bits: u32,
}

impl PortSetting {
    pub const fn live() -> Self {
        Self {
            island_bits: 512,
            fabric_bits: 64,
        }
    }

    pub fn width_ok(bits: u32) -> bool {
        (64..=4096).contains(&bits) && bits.is_power_of_two()
    }

    pub fn carried_bytes(self) -> u32 {
        if !Self::width_ok(self.island_bits) || !Self::width_ok(self.fabric_bits) {
            return 0;
        }
        self.island_bits.min(self.fabric_bits) / 8
    }

    pub fn promoted(self) -> bool {
        self.carried_bytes() > 8
    }
}

/// Section 11 settings. All default off. None of them change a product
/// here, and lane groups do not add MAC/s: spare lanes are already
/// retire-bound.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TrackFeatures {
    pub lane_groups: bool,
    pub float_reductions: bool,
    pub converters: bool,
    pub proof_producers: bool,
    pub approximate_consumers: bool,
    pub clusters: u32,
    pub macs: u32,
}

impl TrackFeatures {
    pub const fn live() -> Self {
        Self {
            lane_groups: false,
            float_reductions: false,
            converters: false,
            proof_producers: false,
            approximate_consumers: false,
            clusters: 1,
            macs: 512,
        }
    }

    /// MAC/cycle the sketch may use. The live port keeps 512. A promoted
    /// port may use the configured count. Lane groups do not raise it.
    pub fn effective_macs(self, port: PortSetting) -> u32 {
        let _ = (
            self.lane_groups,
            self.float_reductions,
            self.converters,
            self.proof_producers,
        );
        if port.promoted() && self.macs > 0 {
            self.macs
        } else {
            512
        }
    }

    /// Cluster count the sketch may use. The live port keeps one cluster.
    pub fn effective_clusters(self, port: PortSetting) -> u32 {
        if port.promoted() && self.clusters > 0 {
            self.clusters
        } else {
            1
        }
    }

    /// Approximate consumers stay unapplied until every promotion gate
    /// is present. That still does not write [`LIVE_VA_TURBO_EN`].
    pub fn approximate_apply(self, gates: PromotionGates) -> bool {
        self.approximate_consumers && gates.ready()
    }
}

/// A ppm figure does not satisfy a promotion gate.
pub fn ppm_satisfies_promotion(_ppm: u32) -> bool {
    false
}

/// Whether this recipe's analytic bound and the measured ppm both fit `level`.
///
/// An exact recipe does not need kappa. Any other recipe needs `kappa_q8`.
/// This does not change a product.
pub fn va_turbo_recipe_claim_fits(
    level: u32,
    recipe: u32,
    measured_ppm: Option<u32>,
    kappa_q8: Option<u32>,
    approx_param: Option<u32>,
) -> bool {
    if recipe > 31 || !va_turbo_measurement_fits(level, measured_ppm) {
        return false;
    }
    let Some(eps) = va_turbo_recipe_eps_ppm(recipe, approx_param, None) else {
        return false;
    };
    if eps == 0 {
        return va_turbo_recipe_admitted(level, 0, 256, measured_ppm.unwrap_or(0));
    }
    match (kappa_q8, measured_ppm) {
        (Some(kappa), Some(caller)) => va_turbo_recipe_admitted(level, eps, kappa, caller),
        _ => false,
    }
}

/// Level applied to arithmetic. Only 0 is applied. A higher level stays a
/// budget check until an error-bound witness exists.
pub fn va_turbo_applied_level(level: u32) -> u32 {
    let _ = level;
    0
}

/// Config-chain inputs of the selector's permission stage.
///
/// Each bit is separate so a live package, the directed test config, or a
/// chain with one gate clear can all be evaluated. This is not class
/// eligibility inside `va_turbo_select`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VaTurboGates {
    pub va_turbo_en: bool,
    pub policy_subcode_en: bool,
    pub policy_benefit_en: bool,
    pub policy_codec_en: bool,
    pub island_fp_en: bool,
    pub matrix_en: bool,
    pub queues: u32,
    pub enable: bool,
}

impl VaTurboGates {
    /// `AiCfgVaTurboTest`: the chain set, one queue, runtime enable on.
    pub const fn directed() -> Self {
        Self {
            va_turbo_en: true,
            policy_subcode_en: true,
            policy_benefit_en: true,
            policy_codec_en: true,
            island_fp_en: true,
            matrix_en: true,
            queues: 1,
            enable: true,
        }
    }

    /// `VaTurboEn` through `Queues > 0`. Runtime enable is predicate 2.
    pub const fn chain(&self) -> bool {
        self.va_turbo_en
            && self.policy_subcode_en
            && self.policy_benefit_en
            && self.policy_codec_en
            && self.island_fp_en
            && self.matrix_en
            && self.queues > 0
    }
}

/// The five predicates `va_turbo_select` requires before it may apply a recipe.
///
/// `permitted` is their conjunction, for any recipe id in `0..=31`. `apply`
/// stays false: the selector is not connected to the MAC path, and
/// [`va_turbo_applied_level`] is 0.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VaTurboPermission {
    pub gates: bool,
    pub level_nonzero: bool,
    pub consumer: bool,
    pub profile: bool,
    pub window: bool,
    pub permitted: bool,
    pub apply: bool,
}

/// Report the selector predicates for one recipe id.
pub fn va_turbo_permission(
    gates: VaTurboGates,
    level: u32,
    recipe: u32,
    consumer_mask: u32,
    profile_mask: u32,
    window_valid: bool,
) -> VaTurboPermission {
    let bit = if recipe <= 31 { 1u32 << recipe } else { 0 };
    let gates_ok = gates.chain();
    let level_nonzero = gates.enable && level > 0 && level <= VA_TURBO_LEVEL_MAX;
    let consumer = recipe <= 31 && consumer_mask & bit != 0;
    let profile = recipe <= 31 && profile_mask & bit != 0;
    let permitted = gates_ok && level_nonzero && consumer && profile && window_valid;
    VaTurboPermission {
        gates: gates_ok,
        level_nonzero,
        consumer,
        profile,
        window: window_valid,
        permitted,
        apply: false,
    }
}

/// Whether a measured ppm may sit under `level`. Level 0 needs no measurement
/// because it does not change a product. A level above 0 with no measurement
/// fails closed. The figure 18,527 ppm is the documented INT8 tile error, not
/// a new measurement.
pub fn va_turbo_measurement_fits(level: u32, measured_ppm: Option<u32>) -> bool {
    if level == 0 {
        return measured_ppm.map(|ppm| ppm == 0).unwrap_or(true);
    }
    match (va_turbo_budget_ppm(level), measured_ppm) {
        (Some(budget), Some(measured)) => measured <= budget,
        _ => false,
    }
}

/// Documented INT8 tile error in `va-turbo.md`. Not re-measured here.
pub const VA_TURBO_DOC_INT8_PPM: u32 = 18_527;

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
            m: 1025,
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
        let tiles = tile_gemm(1024, 1024, 1024, AccTile::ISLAND_P3_DEFAULT);
        // M fits in one 1024-row panel. N and K each take two 512-steps: 4 tiles.
        assert_eq!(tiles.len(), 4);
        assert_eq!(tiles[0].tm, 1024);
        assert_eq!(tiles[0].tn, 512);
        assert_eq!(tiles.last().unwrap().t0, 512);
    }

    #[test]
    fn va_blocking_picks_a_named_panel_inside_the_box() {
        let cap = AccTile::ISLAND_P3_DEFAULT;
        let macs = 512;
        let quarter = va_blocking_tile(1024, 128, 512, cap, macs);
        assert_eq!((quarter.m, quarter.n, quarter.k), (1024, 128, 512));
        assert_eq!(tile_gemm(1024, 128, 512, quarter).len(), 1);

        let half = va_blocking_tile(512, 256, 16, cap, macs);
        assert_eq!((half.m, half.n), (512, 256));
        assert_eq!(tile_gemm(512, 256, 16, half).len(), 1);

        // Same descriptor count as the square panel, and every tile is named.
        // Wider N wins, so the second M tile can reuse B.
        let wide = va_blocking_tile(1024, 256, 512, cap, macs);
        assert_eq!((wide.m, wide.n), (512, 256));
        let tiles = tile_gemm(1024, 256, 512, wide);
        assert_eq!(tiles.len(), 2);
        assert!(tiles.iter().all(|g| g.tm == 512 && g.tn == 256));

        // 129 columns: the 128-wide panel is the only cut with a named tile.
        let edge = va_blocking_tile(1024, 129, 512, cap, macs);
        assert_eq!((edge.m, edge.n), (1024, 128));

        let small = va_blocking_tile(100, 100, 8, cap, macs);
        assert_eq!((small.m, small.n), (512, 512));
        assert_eq!(tile_gemm(100, 100, 8, small).len(), 1);

        let tiny = AccTile { m: 2, n: 2, k: 2 };
        assert_eq!(va_blocking_tile(4, 4, 4, tiny, macs), tiny);
    }

    #[test]
    fn va_turbo_budget_matches_the_geometric_ladder_and_does_not_apply() {
        assert_eq!(va_turbo_budget_ppm(0), Some(0));
        assert_eq!(va_turbo_budget_ppm(1), Some(100));
        assert_eq!(va_turbo_budget_ppm(5), Some(1_600));
        assert_eq!(va_turbo_budget_ppm(8), Some(12_800));
        assert_eq!(va_turbo_budget_ppm(15), Some(1_000_000));
        assert_eq!(va_turbo_budget_ppm(16), None);
        assert_eq!(va_turbo_error_bound_q4(0), Some(0));
        assert_eq!(va_turbo_error_bound_q4(1_600), Some(5));
        assert_eq!(va_turbo_error_bound_q4(1_601), Some(6));
        assert_eq!(va_turbo_error_bound_q4(1_000_001), None);
        assert!(va_turbo_level_within_bound(5, 1_600));
        assert!(!va_turbo_level_within_bound(8, 1_600));
        assert!(!va_turbo_level_within_bound(16, 1_000_000));
        assert!(!va_turbo_level_within_bound(15, 1_000_001));
        // FP16 eps 977 at kappa 1. Level 5 covers it. Level 1 does not.
        assert_eq!(va_turbo_compose_ppm(977, 256), Some(977));
        assert!(va_turbo_recipe_admitted(5, 977, 256, 1_600));
        assert!(!va_turbo_recipe_admitted(1, 977, 256, 1_600));
        assert_eq!(va_turbo_compose_ppm(977, 255), None);
        assert!(!va_turbo_recipe_admitted(5, 977, 255, 1_600));
        for level in 0..=15 {
            assert_eq!(va_turbo_applied_level(level), 0);
        }
        assert!(va_turbo_measurement_fits(0, None));
        assert!(!va_turbo_measurement_fits(0, Some(1)));
        assert!(!va_turbo_measurement_fits(8, None));
        assert!(!va_turbo_measurement_fits(8, Some(VA_TURBO_DOC_INT8_PPM)));
        assert!(va_turbo_measurement_fits(9, Some(VA_TURBO_DOC_INT8_PPM)));
        assert_eq!(va_turbo_applied_level(9), 0);
        assert_eq!(va_turbo_recipe_eps_ppm(16, None, None), Some(0));
        assert_eq!(va_turbo_recipe_eps_ppm(4, None, None), Some(977));
        assert_eq!(va_turbo_recipe_eps_ppm(27, None, None), Some(250_000));
        assert_eq!(va_turbo_recipe_eps_ppm(26, Some(0), None), None);
        assert_eq!(va_turbo_quant_eps_ppm(127, 512), Some(7_892));
        assert!(!va_turbo_recipe_claim_fits(9, 27, Some(VA_TURBO_DOC_INT8_PPM), Some(256), None));
        assert!(va_turbo_recipe_claim_fits(9, 16, Some(VA_TURBO_DOC_INT8_PPM), None, None));
        assert!(va_turbo_recipe_claim_fits(9, 4, Some(VA_TURBO_DOC_INT8_PPM), Some(256), None));
    }

    #[test]
    fn va_turbo_permission_covers_the_chain_and_does_not_apply() {
        let mask = 1u32 << 16;
        let armed = va_turbo_permission(VaTurboGates::directed(), 9, 16, mask, mask, true);
        assert!(armed.gates && armed.level_nonzero && armed.consumer && armed.profile && armed.window);
        assert!(armed.permitted);
        assert!(!armed.apply);
        let mut turbo_off = VaTurboGates::directed();
        turbo_off.va_turbo_en = false;
        let off = va_turbo_permission(turbo_off, 9, 16, mask, mask, true);
        assert!(!off.gates && !off.permitted && !off.apply);
        let mut no_matrix = VaTurboGates::directed();
        no_matrix.matrix_en = false;
        assert!(!va_turbo_permission(no_matrix, 9, 16, mask, mask, true).permitted);
        let mut no_queue = VaTurboGates::directed();
        no_queue.queues = 0;
        assert!(!va_turbo_permission(no_queue, 9, 16, mask, mask, true).gates);
        let mut held = VaTurboGates::directed();
        held.enable = false;
        let paused = va_turbo_permission(held, 9, 16, mask, mask, true);
        assert!(paused.gates && !paused.level_nonzero && !paused.permitted);
        assert!(!va_turbo_permission(VaTurboGates::directed(), 0, 16, mask, mask, true).level_nonzero);
        assert!(!va_turbo_permission(VaTurboGates::directed(), 16, 16, mask, mask, true).level_nonzero);
        let top = 1u32 << 31;
        let last = va_turbo_permission(VaTurboGates::directed(), 15, 31, top, top, true);
        assert!(last.consumer && last.profile && last.permitted && !last.apply);
        let unknown = va_turbo_permission(VaTurboGates::directed(), 9, 32, u32::MAX, u32::MAX, true);
        assert!(!unknown.consumer && !unknown.profile && !unknown.permitted);
        assert!(!va_turbo_permission(VaTurboGates::directed(), 9, 16, mask, mask, false).permitted);
        assert!(!va_turbo_permission(VaTurboGates::directed(), 9, 16, mask, 0, true).profile);
    }

    #[test]
    fn va_turbo_decode_names_every_bank_entry_and_applies_nothing() {
        for id in 0..=31 {
            let row = va_turbo_decode(id, None, None);
            assert!(row.supported, "{id}");
            assert!(row.actions_clear(), "{id}");
        }
        let exact = va_turbo_decode(16, None, None);
        assert_eq!(exact.kind, VaArithKind::Exact);
        assert_eq!(exact.eps_ppm, Some(0));
        assert!(!exact.needs_param && !exact.narrows_storage);
        let fp16 = va_turbo_decode(4, None, None);
        assert_eq!(fp16.kind, VaArithKind::Rel);
        assert_eq!(fp16.eps_ppm, Some(977));
        assert!(fp16.narrows_storage);
        let int8 = va_turbo_decode(6, None, None);
        assert_eq!(int8.kind, VaArithKind::Full);
        assert_eq!(int8.quant_levels, Some(127));
        assert_eq!(int8.eps_ppm, Some(7_892));
        let param = va_turbo_decode(18, None, None);
        assert!(param.needs_param && param.eps_ppm.is_none() && param.actions_clear());
        assert_eq!(va_turbo_decode(18, Some(0), None).eps_ppm, Some(977));
        let sentinel = va_turbo_decode(26, Some(1), None);
        assert_eq!(sentinel.kind, VaArithKind::Rel);
        assert!(sentinel.needs_param && sentinel.eps_ppm.is_none() && sentinel.actions_clear());
        let outside = va_turbo_decode(32, None, None);
        assert!(!outside.supported && outside.actions_clear());
        assert_eq!(outside.kind, VaArithKind::None);
    }

    #[test]
    fn promotion_stays_off_until_all_four_gates_and_does_not_write_the_live_bit() {
        let open = PromotionGates::default();
        assert!(!open.ready());
        assert!(!ppm_satisfies_promotion(VA_TURBO_DOC_INT8_PPM));
        let mut partial = PromotionGates {
            concurrency_measured: true,
            held_out_pair: true,
            gain_threshold_recorded: true,
            beyond_tile_proxy: false,
        };
        assert!(!partial.ready());
        partial.beyond_tile_proxy = true;
        assert!(partial.ready());
        assert!(!va_turbo_en_allowed(true, open));
        assert!(!va_turbo_en_allowed(true, partial));
        assert!(!va_turbo_en_allowed(false, partial));
        let open_decision = va_turbo_decision(true, open);
        assert!(!open_decision.allowed);
        assert_eq!(open_decision.missing, PROMOTION_GATES);
        let ready_decision = va_turbo_decision(true, partial);
        assert!(!ready_decision.allowed && ready_decision.missing.is_empty());
        let known = va_turbo_from_witnesses(
            GateWitness {
                name: "exact_reuse",
                status: "passed",
                source: "huggingface-bert-query-weight",
            },
            &known_promotion_witnesses(),
        );
        assert_eq!(
            accept_witness(GateWitness {
                name: "concurrency_measured",
                status: "passed",
                source: "lane-groups",
            })
            .status,
            "failed"
        );
        assert_eq!(
            accept_witness(GateWitness {
                name: "beyond_tile_proxy",
                status: "passed",
                source: "huggingface-bert-random",
            })
            .status,
            "absent"
        );
        assert!(!known.allowed);
        assert_eq!(
            known.missing,
            [
                "concurrency_measured:failed",
                "held_out_pair:absent",
                "gain_threshold_recorded:absent",
                "beyond_tile_proxy:absent",
            ]
        );
        let passed = [
            GateWitness {
                name: "concurrency_measured",
                status: "passed",
                source: "synthetic-witness",
            },
            GateWitness {
                name: "held_out_pair",
                status: "passed",
                source: "synthetic-witness",
            },
            GateWitness {
                name: "gain_threshold_recorded",
                status: "passed",
                source: "synthetic-witness",
            },
            GateWitness {
                name: "beyond_tile_proxy",
                status: "passed",
                source: "synthetic-witness",
            },
        ];
        let allowed = va_turbo_from_witnesses(
            GateWitness {
                name: "exact_reuse",
                status: "passed",
                source: "synthetic-witness",
            },
            &passed,
        );
        assert!(allowed.allowed && allowed.missing.is_empty());
        assert!(!LIVE_VA_TURBO_EN);
        assert!(!LIVE_VA_TURBO_EN);
        assert!(!section11_selected());
        assert_eq!(SECTION11_OPEN.len(), 6);
        let live = PortSetting::live();
        assert_eq!(live.carried_bytes(), 8);
        assert!(!live.promoted());
        assert_eq!(TrackFeatures::live().effective_macs(live), 512);
        let mut grouped = TrackFeatures::live();
        grouped.lane_groups = true;
        assert_eq!(grouped.effective_macs(live), 512);
        let wide = PortSetting {
            island_bits: 512,
            fabric_bits: 256,
        };
        assert!(wide.promoted());
        assert_eq!(wide.carried_bytes(), 32);
        let mut scaled = TrackFeatures::live();
        scaled.macs = 2048;
        scaled.clusters = 4;
        assert_eq!(scaled.effective_macs(wide), 2048);
        assert_eq!(scaled.effective_macs(live), 512);
        assert!(!PortSetting { island_bits: 96, fabric_bits: 96 }.promoted());
        grouped.approximate_consumers = true;
        assert!(!grouped.approximate_apply(PromotionGates::default()));
        assert!(grouped.approximate_apply(PromotionGates {
            concurrency_measured: true,
            held_out_pair: true,
            gain_threshold_recorded: true,
            beyond_tile_proxy: true,
        }));
        assert!(!LIVE_VA_TURBO_EN);
    }

    #[test]
    fn select_workload_picks_resident_b_for_large_decode_and_applies_nothing() {
        let large = select_workload(1, 256, 256);
        assert_eq!(large.code, POLICY_DECODE);
        assert_eq!(large.exact_recipe, Some(16));
        assert!(large.reuse_b && !large.reuse_a && !large.apply && large.large_decode);
        assert_eq!(large.b_share_millis, 996);
        assert_eq!(large.withheld, 15);
        let small = select_workload(1, 8, 16);
        assert_eq!(small.code, POLICY_DECODE);
        assert_eq!(small.exact_recipe, Some(16));
        assert!(small.reuse_b && !small.large_decode && !small.apply);
        assert_eq!(small.b_share_millis, 888);
        let square = select_workload(8, 8, 16);
        assert_eq!(square.code, POLICY_BULK);
        assert_eq!(square.exact_recipe, None);
        assert!(!square.reuse_b && !square.apply);
        assert_eq!(square.withheld, 15);
        let empty = select_workload(0, 256, 256);
        assert_eq!(empty.code, POLICY_MOVEMENT);
        assert_eq!(empty.exact_recipe, None);
        assert!(!empty.apply);
        let tall = select_workload(256, 1, 256);
        assert_eq!(tall.code, POLICY_TALL);
        assert_eq!(tall.exact_recipe, Some(16));
        assert!(tall.reuse_a && !tall.reuse_b && !tall.apply && !tall.large_decode && tall.large_resident);
        assert_eq!(tall.a_share_millis, 996);
        assert_eq!(tall.withheld, 15);
        let wide = select_workload(8, 16, 16);
        assert_eq!(wide.code, POLICY_WIDE);
        assert_eq!(wide.exact_recipe, None);
        assert!(!wide.reuse_a && !wide.reuse_b && !wide.apply);
    }

    #[test]
    fn admit_withheld_lists_only_ids_the_bound_accepts_and_applies_nothing() {
        let mask = u32::MAX;
        let listed = admit_withheld(
            VaTurboGates::directed(),
            9,
            Some(VA_TURBO_DOC_INT8_PPM),
            Some(256),
            mask,
            mask,
            true,
            None,
        );
        assert!(listed.ids.contains(&4));
        assert!(!listed.ids.contains(&16));
        assert!(!listed.ids.contains(&26));
        assert!(!listed.ids.contains(&27));
        assert!(!listed.apply);
        assert!(listed.ids.iter().all(|id| {
            va_turbo_decode(*id, None, None).kind != VaArithKind::Exact
        }));
        let tight = admit_withheld(
            VaTurboGates::directed(),
            8,
            Some(VA_TURBO_DOC_INT8_PPM),
            Some(256),
            mask,
            mask,
            true,
            None,
        );
        assert!(tight.ids.is_empty() && !tight.apply);
        let closed = admit_withheld(
            VaTurboGates::directed(),
            9,
            Some(VA_TURBO_DOC_INT8_PPM),
            Some(256),
            mask,
            0,
            true,
            None,
        );
        assert!(closed.ids.is_empty());
    }
}
