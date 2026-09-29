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
use ai_tensor_ir::{PortSetting, TrackFeatures};

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

/// Descriptor, C, and completion beats stay this wide on the live fabric.
pub const NARROW_BEAT_BYTES: u32 = 8;

/// Descriptor, C, and completion width. The live setting is 8 bytes.
///
/// A legal width is a power of two from 8 through 512. Anything else
/// carries 0. This does not widen those beats.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ControlSetting {
    pub beat_bytes: u32,
}

impl ControlSetting {
    pub const fn live() -> Self {
        Self {
            beat_bytes: NARROW_BEAT_BYTES,
        }
    }

    pub fn bytes(self) -> u32 {
        if (8..=512).contains(&self.beat_bytes) && self.beat_bytes.is_power_of_two() {
            self.beat_bytes
        } else {
            0
        }
    }
}

/// Bytes/cycle that move. A wider island DMA joined onto a narrower
/// fabric carries the fabric width. 512 onto 64 is still 8.
pub fn carried_bytes_per_cycle(island_bits: u32, fabric_bits: u32) -> u32 {
    island_bits.min(fabric_bits) / 8
}

/// The live MAC count may rise only after the carried port is wider
/// than [`NARROW_BEAT_BYTES`]. This does not widen the port.
pub fn macs_may_rise(bytes_per_cycle: u32) -> bool {
    bytes_per_cycle > NARROW_BEAT_BYTES
}

/// Class-0 nameplate of the carried width. Round only the final GB/s result.
pub fn carried_nameplate_gbps(island_bits: u32, fabric_bits: u32, clock_khz: u32) -> u32 {
    bytes_nameplate_gbps(carried_bytes_per_cycle(island_bits, fabric_bits), clock_khz)
}

fn bytes_nameplate_gbps(bytes: u32, clock_khz: u32) -> u32 {
    (u64::from(bytes) * u64::from(clock_khz) / 1_000_000).min(u64::from(u32::MAX)) as u32
}

/// Class 0 is width_bytes × clock_GHz. Channels do not multiply it.
/// Class 1 is `nch × 19`. Class 2 is 400. Any other class is 0.
pub fn dram_nameplate_gbps(noc_bits: u32, clock_khz: u32, nch: u32, dram_class: u32) -> u32 {
    match dram_class {
        0 => bytes_nameplate_gbps(noc_bits / 8, clock_khz),
        1 => nch.saturating_mul(19),
        2 => 400,
        _ => 0,
    }
}

/// Live package: 1 cluster, 512 MAC/cycle, 2 GHz nameplate.
pub const LIVE_CLUSTERS: u32 = 1;
pub const LIVE_MACS: u32 = 512;
pub const LIVE_CLOCK_KHZ: u32 = 2_000_000;
/// Throughput sketch: 8 clusters, 4096 MAC/cycle, 1.5 GHz. Not elaborated here.
pub const SKU_CLUSTERS: u32 = 8;
pub const SKU_MACS: u32 = 4096;
pub const SKU_CLOCK_KHZ: u32 = 1_500_000;

/// MAC issue rate and the format sketch.
///
/// `macs_per_s` is `clusters × macs × clock`. It does not change with the
/// numeric format. `milli_ops` is [`sketch_milli_tops`]: two operations per
/// INT8 MAC, then scaled by element width. A VA level is not an input.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FormatSketch {
    pub macs_per_s: u64,
    pub milli_ops: u32,
}

/// Rate card for one cluster count, MAC array, clock, and format code.
pub fn format_sketch(clusters: u32, macs: u32, clock_khz: u32, fmt: u8) -> FormatSketch {
    FormatSketch {
        macs_per_s: u64::from(clusters)
            .saturating_mul(u64::from(macs))
            .saturating_mul(u64::from(clock_khz))
            .saturating_mul(1000),
        milli_ops: sketch_milli_tops(clusters, macs, clock_khz, fmt),
    }
}

/// Live milli-ops, throughput-sketch milli-ops, and the integer ratio.
///
/// The ratio is 48 for every format the sketch can express. Structured 2:4
/// and an unknown code are 0 and have ratio 0. This does not raise
/// `AI_LIVE_MACS`.
pub fn tops_gap(fmt: u8) -> (u32, u32, u32) {
    let live = sketch_milli_tops(LIVE_CLUSTERS, LIVE_MACS, LIVE_CLOCK_KHZ, fmt);
    let sku = sketch_milli_tops(SKU_CLUSTERS, SKU_MACS, SKU_CLOCK_KHZ, fmt);
    let gap = if live == 0 { 0 } else { sku / live };
    (live, sku, gap)
}

/// Sketch for one port setting. Not a measurement.
///
/// The live setting stays 1×512 at the given clock. A promoted fabric
/// may use the configured cluster and MAC counts. Descriptor, C, and
/// completion beats stay [`NARROW_BEAT_BYTES`]. Lane groups, reductions,
/// converters, and proof producers do not change the rate. A VA level
/// is not an input.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConfiguredRate {
    pub clusters: u32,
    pub macs: u32,
    pub macs_per_s: u64,
    pub milli_ops: u32,
    pub carried_bytes: u32,
    pub control_beat_bytes: u32,
    pub clock_khz: u32,
    pub promoted: bool,
}

pub fn configured_rate(
    port: PortSetting,
    features: TrackFeatures,
    clock_khz: u32,
    fmt: u8,
) -> ConfiguredRate {
    let clusters = features.effective_clusters(port);
    let macs = features.effective_macs(port);
    let sketch = format_sketch(clusters, macs, clock_khz, fmt);
    ConfiguredRate {
        clusters,
        macs,
        macs_per_s: sketch.macs_per_s,
        milli_ops: sketch.milli_ops,
        carried_bytes: port.carried_bytes(),
        control_beat_bytes: NARROW_BEAT_BYTES,
        clock_khz,
        promoted: port.promoted(),
    }
}

impl ConfiguredRate {
    /// Replace the control-beat width. The live rate uses 8.
    pub fn with_control(self, control: ControlSetting) -> Self {
        Self {
            control_beat_bytes: control.bytes(),
            ..self
        }
    }
}

/// Live intensity: 512 MAC/cycle on 8 bytes/cycle.
pub const LIVE_MACS_PER_BYTE: u32 = 64;

/// Whether the data port and the control beats still feed the array.
///
/// `keeps_pace` is the carried data width. `control_keeps_pace` is the
/// descriptor, C, and completion path, which stays 8 bytes. `fed` is
/// both. A wide data fabric does not widen those beats. This does not
/// widen the live fabric.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PortBalance {
    pub macs_per_cycle: u32,
    pub macs_per_byte: u32,
    pub bytes_to_keep_pace: u32,
    pub keeps_pace: bool,
    pub control_macs_per_byte: u32,
    pub control_keeps_pace: bool,
    pub fed: bool,
    /// Class-0 nameplate in whole GB/s, calculated at kHz clock precision.
    pub data_nameplate_gbps: u32,
    pub control_nameplate_gbps: u32,
    /// Whole GB/s for the assumed 64 MAC/byte balance, not a workload roofline.
    pub demand_gbps: u32,
}

pub fn port_balance(rate: ConfiguredRate) -> PortBalance {
    let total = rate.clusters.saturating_mul(rate.macs);
    let bytes = rate.carried_bytes;
    let control = rate.control_beat_bytes;
    let keeps_pace = bytes > 0 && total <= bytes.saturating_mul(LIVE_MACS_PER_BYTE);
    let control_keeps_pace = control > 0 && total <= control.saturating_mul(LIVE_MACS_PER_BYTE);
    let needed = total.div_ceil(LIVE_MACS_PER_BYTE);
    PortBalance {
        macs_per_cycle: total,
        macs_per_byte: if bytes == 0 { 0 } else { total / bytes },
        bytes_to_keep_pace: needed,
        keeps_pace,
        control_macs_per_byte: if control == 0 { 0 } else { total / control },
        control_keeps_pace,
        fed: keeps_pace && control_keeps_pace,
        data_nameplate_gbps: bytes_nameplate_gbps(bytes, rate.clock_khz),
        control_nameplate_gbps: bytes_nameplate_gbps(control, rate.clock_khz),
        demand_gbps: bytes_nameplate_gbps(needed, rate.clock_khz),
    }
}

/// Class 0 is the carried data nameplate. Class 1 is `channels × 19`.
/// Class 2 is 400 and ignores width and clock. Any other class is 0.
pub fn dram_cap_gbps(class: u32, channels: u32, data_nameplate_gbps: u32) -> u32 {
    match class {
        0 => data_nameplate_gbps,
        1 => channels.saturating_mul(19),
        2 => 400,
        _ => 0,
    }
}

/// The DRAM cap covers the array only when the setting is fed and the
/// cap is at least [`PortBalance::demand_gbps`]. This does not change
/// the live DRAM class.
pub fn dram_covers(balance: PortBalance, class: u32, channels: u32) -> bool {
    let cap = dram_cap_gbps(class, channels, balance.data_nameplate_gbps);
    balance.fed && balance.demand_gbps > 0 && cap >= balance.demand_gbps
}

/// The claimed GB/s has to equal the class formula.
///
/// Class 2 is 400, and that claim is rejected when it is also the class-0
/// nameplate. A matching claim does not change the live DRAM class.
pub fn dram_claim_matches(
    class: u32,
    channels: u32,
    data_nameplate_gbps: u32,
    claimed_gbps: u32,
) -> bool {
    if class > 2 {
        return false;
    }
    let cap = dram_cap_gbps(class, channels, data_nameplate_gbps);
    claimed_gbps == cap && !(class == 2 && claimed_gbps == data_nameplate_gbps)
}

/// DDR4-2400×64 channels needed to cover `demand_gbps`. Each channel is 19.
pub fn ddr4_channels_to_cover(demand_gbps: u32) -> u32 {
    if demand_gbps == 0 {
        0
    } else {
        demand_gbps.div_ceil(19)
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
    fn nameplates_preserve_fractional_ghz() {
        for (clock, expected) in [(500_000, 4), (1_250_000, 10), (1_500_000, 12), (2_000_000, 16)] {
            assert_eq!(carried_nameplate_gbps(512, 64, clock), expected);
            assert_eq!(dram_nameplate_gbps(64, clock, 8, 0), expected);
            let rate = configured_rate(PortSetting::live(), TrackFeatures::live(), clock, 0);
            let balance = port_balance(rate);
            assert_eq!(balance.data_nameplate_gbps, expected);
            assert_eq!(balance.control_nameplate_gbps, expected);
            assert_eq!(balance.demand_gbps, expected);
        }
        assert_eq!(carried_nameplate_gbps(u32::MAX, u32::MAX, u32::MAX), u32::MAX);
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
        let live = format_sketch(LIVE_CLUSTERS, LIVE_MACS, LIVE_CLOCK_KHZ, 0);
        assert_eq!(live.macs_per_s, 1_024_000_000_000);
        assert_eq!(live.milli_ops, 2_048);
        assert_eq!(format_sketch(LIVE_CLUSTERS, LIVE_MACS, LIVE_CLOCK_KHZ, 1).milli_ops, 4_096);
        assert_eq!(format_sketch(LIVE_CLUSTERS, LIVE_MACS, LIVE_CLOCK_KHZ, 5).milli_ops, 1_024);
        assert_eq!(format_sketch(LIVE_CLUSTERS, LIVE_MACS, LIVE_CLOCK_KHZ, 7).milli_ops, 512);
        let sku = format_sketch(SKU_CLUSTERS, SKU_MACS, SKU_CLOCK_KHZ, 0);
        assert_eq!(sku.milli_ops, 98_304);
        assert_eq!(sku.macs_per_s, 49_152_000_000_000);
        for fmt in [0u8, 1, 3, 4, 5, 6, 7] {
            assert_eq!(tops_gap(fmt).2, 48, "fmt {fmt}");
            assert_eq!(
                sketch_milli_tops_scaled(LIVE_CLUSTERS, LIVE_MACS, LIVE_CLOCK_KHZ, fmt, 1, 1, 9),
                sketch_milli_tops(LIVE_CLUSTERS, LIVE_MACS, LIVE_CLOCK_KHZ, fmt),
                "fmt {fmt}"
            );
        }
        assert_eq!(tops_gap(2), (0, 0, 0));
        assert_eq!(carried_bytes_per_cycle(512, 64), 8);
        assert_eq!(carried_bytes_per_cycle(64, 512), 8);
        assert_eq!(carried_bytes_per_cycle(512, 512), 64);
        assert!(!macs_may_rise(carried_bytes_per_cycle(512, 64)));
        assert!(macs_may_rise(carried_bytes_per_cycle(512, 512)));
        assert_eq!(carried_nameplate_gbps(512, 64, 2_000_000), 16);
        assert_eq!(carried_nameplate_gbps(512, 512, 2_000_000), 128);
        assert_eq!(NARROW_BEAT_BYTES, 8);
        let live_rate = configured_rate(
            PortSetting::live(),
            TrackFeatures::live(),
            LIVE_CLOCK_KHZ,
            0,
        );
        assert!(!live_rate.promoted);
        assert_eq!(live_rate.clusters, 1);
        assert_eq!(live_rate.macs, 512);
        assert_eq!(live_rate.milli_ops, 2_048);
        assert_eq!(live_rate.carried_bytes, 8);
        assert_eq!(live_rate.control_beat_bytes, 8);
        let mut scaled = TrackFeatures::live();
        scaled.clusters = 4;
        scaled.macs = 2048;
        scaled.lane_groups = true;
        scaled.float_reductions = true;
        scaled.converters = true;
        scaled.proof_producers = true;
        let wide = PortSetting {
            island_bits: 512,
            fabric_bits: 256,
        };
        let promoted = configured_rate(wide, scaled, LIVE_CLOCK_KHZ, 0);
        assert!(promoted.promoted);
        assert_eq!(promoted.clusters, 4);
        assert_eq!(promoted.macs, 2048);
        assert_eq!(promoted.milli_ops, 32_768);
        assert_eq!(promoted.macs_per_s, 16_384_000_000_000);
        assert_eq!(promoted.carried_bytes, 32);
        assert_eq!(promoted.control_beat_bytes, 8);
        assert_eq!(configured_rate(wide, scaled, LIVE_CLOCK_KHZ, 1).milli_ops, 65_536);
        assert_eq!(configured_rate(wide, scaled, LIVE_CLOCK_KHZ, 5).milli_ops, 16_384);
        assert_eq!(configured_rate(wide, scaled, LIVE_CLOCK_KHZ, 7).milli_ops, 8_192);
        assert_eq!(configured_rate(PortSetting::live(), scaled, LIVE_CLOCK_KHZ, 0).milli_ops, 2_048);
        let live_balance = port_balance(live_rate);
        assert_eq!(live_balance.macs_per_byte, 64);
        assert_eq!(live_balance.bytes_to_keep_pace, 8);
        assert!(live_balance.keeps_pace && live_balance.control_keeps_pace && live_balance.fed);
        assert_eq!(live_balance.data_nameplate_gbps, 16);
        assert_eq!(live_balance.control_nameplate_gbps, 16);
        assert_eq!(live_balance.demand_gbps, 16);
        assert!(dram_covers(live_balance, 0, 1));
        assert!(!dram_covers(live_balance, 3, 1));
        assert!(dram_claim_matches(0, 1, live_balance.data_nameplate_gbps, 16));
        assert!(!dram_claim_matches(0, 1, live_balance.data_nameplate_gbps, 400));
        assert_eq!(ddr4_channels_to_cover(16), 1);
        let wide_balance = port_balance(promoted);
        assert_eq!(wide_balance.macs_per_cycle, 8_192);
        assert_eq!(wide_balance.macs_per_byte, 256);
        assert_eq!(wide_balance.bytes_to_keep_pace, 128);
        assert!(!wide_balance.keeps_pace);
        let mut sku = TrackFeatures::live();
        sku.clusters = SKU_CLUSTERS;
        sku.macs = SKU_MACS;
        let fabric = PortSetting {
            island_bits: 4096,
            fabric_bits: 4096,
        };
        let sku_balance = port_balance(configured_rate(fabric, sku, SKU_CLOCK_KHZ, 0));
        assert_eq!(sku_balance.macs_per_cycle, 32_768);
        assert_eq!(sku_balance.macs_per_byte, 64);
        assert_eq!(sku_balance.bytes_to_keep_pace, 512);
        assert!(sku_balance.keeps_pace);
        assert_eq!(sku_balance.control_macs_per_byte, 4_096);
        assert!(!sku_balance.control_keeps_pace && !sku_balance.fed);
        let opened = port_balance(
            configured_rate(fabric, sku, SKU_CLOCK_KHZ, 0).with_control(ControlSetting { beat_bytes: 512 }),
        );
        assert_eq!(opened.control_macs_per_byte, 64);
        assert!(opened.keeps_pace && opened.control_keeps_pace && opened.fed);
        assert_eq!(opened.data_nameplate_gbps, 768);
        assert_eq!(opened.control_nameplate_gbps, 768);
        assert_eq!(opened.demand_gbps, 768);
        assert!(dram_covers(opened, 0, 1));
        assert!(!dram_covers(opened, 2, 1));
        assert!(dram_claim_matches(2, 1, opened.data_nameplate_gbps, 400));
        assert!(!dram_claim_matches(2, 1, 400, 400));
        assert_eq!(ddr4_channels_to_cover(512), 27);
        assert_eq!(ddr4_channels_to_cover(768), 41);
        assert!(dram_covers(opened, 1, 41));
        assert!(!dram_covers(opened, 1, 40));
        let still_narrow = port_balance(
            configured_rate(fabric, sku, SKU_CLOCK_KHZ, 0).with_control(ControlSetting::live()),
        );
        assert!(!still_narrow.fed);
        assert!(!dram_covers(still_narrow, 0, 1));
        assert_eq!(ControlSetting { beat_bytes: 12 }.bytes(), 0);
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
