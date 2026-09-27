// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! One GEMM record shared by sim, SoftIsland, virt-card, and qemu-uio.
//!
//! The record is the descriptor fields those backends already carry (`numfmt`,
//! shape, VA level) plus the status they returned. It has no cycle count.
//! A live mask of INT8|INT4 grants codes 0 and 1. Code 2 (structured 2:4) is
//! refused on every mask. Codes 3–7 also need a float datapath: the fast mask
//! bit alone is not acceptance. `fp_datapath` is false for the synthesizable
//! integer strip and true only for the simulation reference.

use ai_tensor_abi::{Desc64, NumFmt, ST_BAD_FMT, ST_OK};

/// Live island grant: `AiIslandPeImplMask` INT8|INT4.
pub const LIVE_DTYPE_MASK: u16 = 0x0003;
/// Non-default cluster grant: every ISA format except structured 2:4.
pub const FAST_DTYPE_MASK: u16 = 0x00fb;

/// Parameter sketch in milli-TOPS. Matches `sketch_milli_tops` in
/// `g6lc_ai_island_cfg_pkg`. Not a measurement. The live package is
/// 512 MAC/cycle at a 2 GHz nameplate (2048 milli-TOPS, 16 GB/s). A VA
/// level does not multiply that rate. The 256-MAC array at 1 GHz is 512
/// milli-TOPS.
///
/// INT8 is `2 × clusters × macs × (clock_khz/1000) / 1000`. Other codes scale
/// by element width: INT4 ×2, FP8 ×1, FP16/BF16 ÷2, FP32 ÷4. Structured 2:4
/// and any unknown code are 0.
pub fn sketch_milli_tops(clusters: u32, macs: u32, clock_khz: u32, fmt: u8) -> u32 {
    let base = (2u64 * u64::from(clusters) * u64::from(macs) * (u64::from(clock_khz) / 1000))
        / 1000;
    let base = base as u32;
    match fmt {
        0 | 3 | 4 => base,
        1 => base.saturating_mul(2),
        5 | 6 => base / 2,
        7 => base / 4,
        _ => 0,
    }
}

/// `sketch_milli_tops` times `mac_mul / mac_div`.
///
/// `mac_mul` projects extra issue groups. It does not describe the elaborated
/// PE array. `va_level` is the VA-turbo error-budget index. Levels 0 through
/// 15 leave the dense peak unchanged: lane groups inside one engine do not
/// add MAC/cycle, and level 0 is the exact path. A level above 15, or a zero
/// multiplier, is not a peak.
pub fn sketch_milli_tops_scaled(
    clusters: u32,
    macs: u32,
    clock_khz: u32,
    fmt: u8,
    mac_mul: u32,
    mac_div: u32,
    va_level: u32,
) -> u32 {
    if mac_mul == 0 || mac_div == 0 || va_level > 15 {
        return 0;
    }
    let milli = u64::from(sketch_milli_tops(clusters, macs, clock_khz, fmt));
    if milli != 0 && u64::from(mac_mul) > u64::from(u32::MAX) / milli {
        return 0;
    }
    (milli * u64::from(mac_mul) / u64::from(mac_div)) as u32
}

/// Class 0 is width_bytes × clock_GHz. Channels do not multiply it.
/// Class 1 is `nch × 19`. Class 2 is 400. Any other class is 0.
pub fn dram_nameplate_gbps(noc_bits: u32, clock_khz: u32, nch: u32, dram_class: u32) -> u32 {
    match dram_class {
        0 => (noc_bits / 8) * (clock_khz / 1_000_000),
        1 => nch.saturating_mul(19),
        2 => 400,
        _ => 0,
    }
}

/// Issues of `macs` products along K. A K that fits in one tile is one
/// issue, so a short K does not finish in fewer issues. `k == 0` or
/// `k > max_k` does not fit that panel.
pub fn va_panel_ok(m: u32, n: u32) -> bool {
    matches!((m, n), (512, 512) | (512, 256) | (1024, 128))
}

pub fn panel_k_issues(k: u32, macs: u32, max_k: u32) -> u32 {
    if k == 0 || macs == 0 || k > max_k {
        return 0;
    }
    k.div_ceil(macs)
}

/// MAC issues for an `m×n×k` panel inside `max_m × max_n × max_k`.
/// The live box is 1024×512×512 and the issue width is `macs`.
/// A VA residency hit does not change this count.
pub fn panel_mac_issues(
    m: u32,
    n: u32,
    k: u32,
    macs: u32,
    max_m: u32,
    max_n: u32,
    max_k: u32,
) -> u32 {
    if m == 0 || n == 0 || m > max_m || n > max_n {
        return 0;
    }
    let issues = panel_k_issues(k, macs, max_k);
    if issues == 0 {
        return 0;
    }
    let outs = u64::from(m) * u64::from(n);
    let prod = outs * u64::from(issues);
    if prod > u64::from(u32::MAX) {
        return 0;
    }
    prod as u32
}

/// INT8 bytes of one operand panel (`rows × k`). A VA hit skips this many
/// bytes. It is not a MAC count.
pub fn panel_operand_bytes(rows: u32, k: u32, max_rows: u32, max_k: u32) -> u32 {
    if rows == 0 || k == 0 || rows > max_rows || k > max_k {
        return 0;
    }
    let prod = u64::from(rows) * u64::from(k);
    if prod > u64::from(u32::MAX) {
        return 0;
    }
    prod as u32
}

/// Class-0 projection. Width and clock multipliers do not change class 1 or
/// class 2. A zero multiplier is not a nameplate.
pub fn bumped_dram_gbps(
    noc_bits: u32,
    clock_khz: u32,
    nch: u32,
    dram_class: u32,
    width_mul: u32,
    clock_mul: u32,
) -> u32 {
    if width_mul == 0 || clock_mul == 0 {
        return 0;
    }
    if dram_class != 0 {
        return dram_nameplate_gbps(noc_bits, clock_khz, nch, dram_class);
    }
    dram_nameplate_gbps(
        noc_bits.saturating_mul(width_mul),
        clock_khz.saturating_mul(clock_mul),
        nch,
        dram_class,
    )
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FormatTrace {
    pub numfmt: u8,
    pub m: u32,
    pub n: u32,
    pub k: u32,
    pub va_level: u8,
    pub status: u16,
}

impl FormatTrace {
    /// Status for this format under `mask`, given whether a float datapath exists.
    ///
    /// Integer codes need only the mask bit. Float codes need the bit and
    /// `fp_datapath`. Structured 2:4 is always `ST_BAD_FMT`. VA level is
    /// recorded and does not change the status.
    pub fn from_request(
        fmt: NumFmt,
        m: u32,
        n: u32,
        k: u32,
        va_level: u8,
        mask: u16,
        fp_datapath: bool,
    ) -> Self {
        let float = matches!(
            fmt,
            NumFmt::Fp8E4m3 | NumFmt::Fp8E5m2 | NumFmt::Fp16 | NumFmt::Bf16 | NumFmt::Fp32
        );
        let status = if fmt == NumFmt::Sp24
            || mask & fmt.grant_bit() == 0
            || (float && !fp_datapath)
        {
            ST_BAD_FMT
        } else {
            ST_OK
        };
        Self {
            numfmt: fmt.abi() as u8,
            m,
            n,
            k,
            va_level,
            status,
        }
    }

    /// Record a descriptor the host or the emulator actually submitted.
    ///
    /// `va_level` stays 0. `VaTurboEn` is off, and the descriptor has no
    /// approximate-execution field yet.
    pub fn from_desc(d: &Desc64, status: u16) -> Self {
        let numfmt = NumFmt::from_flags(d.flags)
            .map(|f| f.abi() as u8)
            .unwrap_or(0xff);
        Self {
            numfmt,
            m: d.m,
            n: d.n,
            k: d.k,
            va_level: 0,
            status,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn eight_codes_against_the_live_mask() {
        let want = [
            (NumFmt::Int, ST_OK),
            (NumFmt::Int4, ST_OK),
            (NumFmt::Sp24, ST_BAD_FMT),
            (NumFmt::Fp8E4m3, ST_BAD_FMT),
            (NumFmt::Fp8E5m2, ST_BAD_FMT),
            (NumFmt::Fp16, ST_BAD_FMT),
            (NumFmt::Bf16, ST_BAD_FMT),
            (NumFmt::Fp32, ST_BAD_FMT),
        ];
        for (fmt, st) in want {
            let rec = FormatTrace::from_request(fmt, 2, 2, 2, 0, LIVE_DTYPE_MASK, false);
            assert_eq!(rec.status, st, "{}", fmt.as_str());
            assert_eq!(rec.numfmt, fmt.abi() as u8);
        }
    }

    #[test]
    fn fast_mask_needs_a_float_datapath_and_still_refuses_sp24() {
        for fmt in [
            NumFmt::Int,
            NumFmt::Int4,
            NumFmt::Fp8E4m3,
            NumFmt::Fp8E5m2,
            NumFmt::Fp16,
            NumFmt::Bf16,
            NumFmt::Fp32,
        ] {
            let with_model = FormatTrace::from_request(fmt, 2, 2, 2, 3, FAST_DTYPE_MASK, true);
            assert_eq!(with_model.status, ST_OK, "{}", fmt.as_str());
            assert_eq!(with_model.va_level, 3, "VA level is recorded, not executed");
            let bare = FormatTrace::from_request(fmt, 2, 2, 2, 0, FAST_DTYPE_MASK, false);
            let float = !matches!(fmt, NumFmt::Int | NumFmt::Int4);
            assert_eq!(bare.status, if float { ST_BAD_FMT } else { ST_OK }, "{}", fmt.as_str());
        }
        let sp = FormatTrace::from_request(NumFmt::Sp24, 2, 2, 2, 0, FAST_DTYPE_MASK, true);
        assert_eq!(sp.status, ST_BAD_FMT);
    }

    #[test]
    fn throughput_sketch_matches_the_rtl_milli_tops() {
        // 8 × 4096 MAC/cycle at 1.5 GHz, the AiIslandThroughputSku parameters.
        let row = |fmt| sketch_milli_tops(8, 4096, 1_500_000, fmt);
        assert_eq!(sketch_milli_tops(1, 256, 1_000_000, 0), 512);
        assert_eq!(sketch_milli_tops(1, 256, 2_000_000, 0), 1_024);
        assert_eq!(sketch_milli_tops(1, 512, 2_000_000, 0), 2_048);
        assert_eq!(
            sketch_milli_tops_scaled(1, 512, 2_000_000, 0, 1, 1, 0),
            2_048
        );
        assert_eq!(
            sketch_milli_tops_scaled(1, 512, 2_000_000, 0, 2, 1, 0),
            4_096
        );
        assert_eq!(
            sketch_milli_tops_scaled(1, 512, 2_000_000, 0, 1, 1, 8),
            2_048,
            "a VA level must not scale the dense peak"
        );
        assert_eq!(sketch_milli_tops_scaled(1, 512, 2_000_000, 0, 1, 1, 16), 0);
        assert_eq!(sketch_milli_tops_scaled(1, 512, 2_000_000, 1, 1, 1, 0), 4_096);
        assert_eq!(dram_nameplate_gbps(64, 2_000_000, 8, 0), 16);
        assert_eq!(bumped_dram_gbps(64, 2_000_000, 1, 0, 2, 1), 32);
        assert_eq!(bumped_dram_gbps(64, 1_000_000, 2, 1, 4, 4), 38);
        assert_eq!(bumped_dram_gbps(512, 1_500_000, 1, 2, 2, 2), 400);
        assert_eq!(bumped_dram_gbps(64, 2_000_000, 1, 0, 0, 1), 0);
        assert!(va_panel_ok(512, 512) && va_panel_ok(512, 256) && va_panel_ok(1024, 128));
        assert!(!va_panel_ok(1024, 256));
        assert_eq!(panel_k_issues(16, 512, 512), 1);
        assert_eq!(panel_k_issues(512, 512, 512), 1);
        assert_eq!(panel_k_issues(513, 512, 512), 0);
        assert_eq!(panel_mac_issues(512, 512, 512, 512, 1024, 512, 512), 262_144);
        assert_eq!(panel_mac_issues(512, 512, 16, 512, 1024, 512, 512), 262_144);
        assert_eq!(panel_mac_issues(512, 256, 512, 512, 1024, 512, 512), 131_072);
        assert_eq!(panel_mac_issues(1024, 128, 512, 512, 1024, 512, 512), 131_072);
        // 129 columns still fit N≤512. 513 columns and 1025 rows do not.
        assert_eq!(panel_mac_issues(1024, 129, 512, 512, 1024, 512, 512), 132_096);
        assert_eq!(panel_mac_issues(1024, 513, 512, 512, 1024, 512, 512), 0);
        assert_eq!(panel_mac_issues(1025, 128, 512, 512, 1024, 512, 512), 0);
        assert_eq!(panel_operand_bytes(512, 512, 1024, 512), 262_144);
        assert_eq!(panel_operand_bytes(1024, 512, 1024, 512), 524_288);
        assert_eq!(panel_operand_bytes(128, 512, 1024, 512), 65_536);
        assert_eq!(panel_operand_bytes(256, 512, 1024, 512), 131_072);
        assert_eq!(row(0), 98_304);
        assert_eq!(row(1), 196_608);
        assert_eq!(row(2), 0);
        assert_eq!(row(3), 98_304);
        assert_eq!(row(4), 98_304);
        assert_eq!(row(5), 49_152);
        assert_eq!(row(6), 49_152);
        assert_eq!(row(7), 24_576);
    }
}
