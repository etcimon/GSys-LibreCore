// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! D2 analytic performance bound for the AI island.
//!
//! This is **not** a cycle simulation, and nothing here observes an execution. It is the
//! arithmetic of `architecture/ai-matrix/scaling-100tops.md` §4 applied to the *ingested*
//! island geometry: given a GEMM shape and the design's own published cluster count,
//! MAC rate, blocking factor, clock and DRAM class, it states the two bounds the shape
//! cannot beat and says which one dominates.
//!
//! Why the package carries it at all: the island's stated target is two orders of magnitude
//! above the live configuration, and the documented failure mode for that climb is widening
//! the MAC array ahead of the memory system (§11). That mistake is invisible in a functional
//! model and obvious in a bound. Producing the bound from ingested values — rather than from
//! numbers retyped out of the plan — is what makes it track the design instead of the document.
//!
//! Three disciplines apply, and they are the reason this stays a *bound*:
//!
//! - **A bound is not a prediction of achieved cycles.** Every counter is [`Fidelity::Modelled`]:
//!   the geometry is the design's, the arithmetic is exact, and the achieved value will be worse.
//!   `Modelled` is not comparable for equality with hardware, which is the correct restriction.
//! - **An unmeasured DRAM class yields no bandwidth bound.** The live configuration publishes
//!   `DramGBps = 0` ("not measured"), so [`Roofline::dram_bound_cycles`] is `None` rather than
//!   zero or infinite. A part whose memory system is unmeasured has no computable roofline, which
//!   is exactly why §11 orders I3 (measure bandwidth) ahead of I2 (add clusters). If a measured
//!   value is later supplied via [`AiIslandConfig::measured_dram_gbps_x1000`], it takes
//!   precedence over the nameplate and the bound closes.
//! - **Utilisation is only meaningful against a measurement.** [`Roofline::utilisation_percent`]
//!   takes a measured cycle count from the design side; the package never invents one.

use crate::{Counter, Fidelity};
use g6q_core::model::AiIslandConfig;

/// Which resource limits a shape on this island.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Bound {
    /// The MAC array is the limit: arithmetic intensity is above the machine balance.
    Compute,
    /// The memory system is the limit: arithmetic intensity is below the machine balance.
    Bandwidth,
    /// The DRAM class is not published, so the bandwidth side cannot be computed.
    Unresolved,
}

impl Bound {
    /// Stable wire name.
    pub fn as_str(self) -> &'static str {
        match self {
            Bound::Compute => "compute",
            Bound::Bandwidth => "bandwidth",
            Bound::Unresolved => "unresolved",
        }
    }
}

/// Analytic bound for one GEMM shape on the ingested island geometry.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Roofline {
    /// Multiply-accumulates the shape requires, `m * n * k`.
    pub macs: u64,
    /// Aggregate MAC rate per cycle: `clusters * macs_per_cycle`.
    ///
    /// Clusters multiply the rate rather than dividing the blocking factor, because §4.1
    /// requires clusters to *cooperate* on one output block. Independent per-cluster
    /// blocking would collapse the effective `T` and is the bandwidth trap named there.
    pub macs_per_cycle_total: u64,
    /// Cycles the MAC array needs at full utilisation.
    pub mac_bound_cycles: u64,
    /// On-chip blocking factor `T`, the side of the output block held on chip.
    ///
    /// From the accumulator geometry (`min(acc_tile_m, acc_tile_n)`), not from a PE array
    /// dimension — §4.1 is explicit that conflating the two is the likely implementation error.
    pub blocking_t: u64,
    /// Whether the shape fits the published per-dimension blocking limit.
    ///
    /// `false` means software must tile the shape before submitting it: the descriptor
    /// contract bounds each of `m`, `n`, `k` by the corresponding accumulator tile, and a
    /// shape past that limit is rejected rather than blocked by hardware. A bound computed
    /// for a shape the contract will not accept describes a machine that does not exist, so
    /// this travels with the result.
    pub shape_fits_blocking: bool,
    /// Input bytes any schedule must read at least once: `m*k + k*n`.
    ///
    /// This is a floor with no dataflow assumption in it — the operands have to be read.
    pub compulsory_read_bytes: u64,
    /// Input bytes a `T`-blocked streaming schedule reads: `macs * 2 / T` (§4).
    ///
    /// Above `T` this exceeds the compulsory floor, because each operand block is re-read
    /// once per output block it contributes to. Below `T` it drops under the floor, which is
    /// why the reported figure takes the larger of the two.
    pub tiled_read_bytes: u64,
    /// DRAM read bytes: the larger of the compulsory floor and the tiled re-read model.
    pub dram_read_bytes: u64,
    /// DRAM write bytes for the accumulator writeback: `4 * m * n`.
    ///
    /// The plan's §4 derivation counts *input* bytes only. At the shapes this engine accepts
    /// that omission is not small: `s32` accumulators make the writeback `4*m*n`, which at
    /// `m = n = k = T` is twice the input traffic.
    pub dram_write_bytes: u64,
    /// Total DRAM bytes moved, reads plus the accumulator writeback.
    pub dram_bytes: u64,
    /// Cycles the memory system needs, when the DRAM class is published.
    pub dram_bound_cycles: Option<u64>,
    /// Machine balance in MAC per byte: `MAC-rate / DRAM-bandwidth` (§4).
    ///
    /// Every kernel with arithmetic intensity below this is bandwidth-bound on this part.
    pub balance_mac_per_byte: Option<u64>,
    /// Arithmetic intensity of the shape in MAC per total DRAM byte.
    ///
    /// Computed from [`Roofline::dram_bytes`], so it accounts for both the compulsory-read
    /// floor and the accumulator writeback. It is therefore *not* the `T / 2` figure §4
    /// quotes: that value is the input-only intensity of an ideal `T`-blocked schedule at a
    /// shape large enough to need re-reads, and it is optimistic at every other shape.
    pub intensity_mac_per_byte: u64,
    /// Input-only arithmetic intensity of an ideal `T`-blocked schedule: `T / 2`.
    ///
    /// Kept separately because it is the number §4 reasons with, and comparing it against
    /// [`Roofline::intensity_mac_per_byte`] shows what the writeback and the small-shape
    /// floor cost.
    pub tiled_input_intensity_mac_per_byte: u64,
    /// Which resource limits the shape.
    pub bound: Bound,
}

/// Compute the analytic bound for a GEMM shape, or `None` if the geometry is unresolved.
///
/// Returns `None` when the design publishes no MAC rate or no blocking factor: a bound
/// derived from a guessed array width or a guessed tile would be a plausible-looking wrong
/// number, which is worse than no number.
pub fn gemm(cfg: &AiIslandConfig, m: u64, n: u64, k: u64) -> Option<Roofline> {
    let per_cluster = cfg.macs_per_cycle as u64;
    let clusters = (cfg.clusters as u64).max(1);
    let macs_per_cycle_total = per_cluster.checked_mul(clusters)?;
    if macs_per_cycle_total == 0 {
        return None;
    }

    // T is the side of the on-chip output block, from the accumulator geometry.
    let blocking_t = (cfg.acc_tile_m as u64).min(cfg.acc_tile_n as u64);
    if blocking_t == 0 {
        return None;
    }

    let macs = m.checked_mul(n)?.checked_mul(k)?;
    let mac_bound_cycles = macs.div_ceil(macs_per_cycle_total);

    // The descriptor contract bounds each dimension by its accumulator tile. A shape past
    // the limit is rejected, not blocked by hardware, so software must tile it first.
    let shape_fits_blocking = m <= cfg.acc_tile_m as u64
        && n <= cfg.acc_tile_n as u64
        && k <= (cfg.acc_tile_k as u64).max(1);

    // Two read models, and the reported figure is the larger:
    //
    //   * compulsory: the operands must be read at least once. No dataflow assumption.
    //   * tiled: §4's `2 / T` bytes per MAC, i.e. each block re-read once per output block
    //     it feeds. Above T this exceeds the floor; below T it falls under it.
    //
    // Taking the max is what makes the bound correct at both ends. Using `2 / T` alone
    // understates a small shape -- a resident schedule still reads `m*k + k*n` -- and using
    // the floor alone understates a large one, which is the re-read trap §4.1 names.
    let compulsory_read_bytes = m.checked_mul(k)?.checked_add(k.checked_mul(n)?)?;
    let tiled_read_bytes = macs.checked_mul(2)? / blocking_t;
    let dram_read_bytes = compulsory_read_bytes.max(tiled_read_bytes);

    // Accumulator writeback. `s32` is the published accumulator format: both §4 and §6 size
    // accumulator SRAM as `T^2 * 4 B`, and the island's C tile banks are 32-bit. If the
    // design ever makes the accumulator width configurable this must become model-derived.
    const ACC_BYTES: u64 = 4;
    let dram_write_bytes = ACC_BYTES.checked_mul(m)?.checked_mul(n)?;

    let dram_bytes = dram_read_bytes.checked_add(dram_write_bytes)?;
    let intensity_mac_per_byte = if dram_bytes == 0 {
        0
    } else {
        macs / dram_bytes
    };
    let tiled_input_intensity_mac_per_byte = blocking_t / 2;

    // Bytes the memory system delivers per island cycle. The bandwidth can come from either
    // the nameplate `dram_gbps` or from a measured `measured_dram_gbps_x1000` value; the
    // measured value takes precedence. Either side missing leaves the bandwidth bound
    // unresolved.
    let clock_hz = (cfg.clock_khz as u64).checked_mul(1_000)?;
    let gbps_x1000 = cfg
        .measured_dram_gbps_x1000
        .filter(|m| *m > 0)
        .map(|m| m as u64)
        .or_else(|| {
            if cfg.dram_gbps > 0 {
                Some(cfg.dram_gbps as u64 * 1_000)
            } else {
                None
            }
        });
    let (dram_bound_cycles, balance_mac_per_byte, bound) = if gbps_x1000.is_none() || clock_hz == 0
    {
        (None, None, Bound::Unresolved)
    } else {
        // gbps_x1000 is in milli-GB/s: gbps * 1_000_000_000 / 1_000.
        let dram_bytes_per_sec = gbps_x1000.unwrap().checked_mul(1_000_000)?;
        let bytes_per_cycle = dram_bytes_per_sec / clock_hz;
        if bytes_per_cycle == 0 {
            (None, None, Bound::Unresolved)
        } else {
            let cycles = dram_bytes.div_ceil(bytes_per_cycle);
            let balance = macs_per_cycle_total / bytes_per_cycle;
            let bound = if intensity_mac_per_byte >= balance {
                Bound::Compute
            } else {
                Bound::Bandwidth
            };
            (Some(cycles), Some(balance), bound)
        }
    };

    Some(Roofline {
        macs,
        macs_per_cycle_total,
        mac_bound_cycles,
        blocking_t,
        shape_fits_blocking,
        compulsory_read_bytes,
        tiled_read_bytes,
        dram_read_bytes,
        dram_write_bytes,
        dram_bytes,
        dram_bound_cycles,
        balance_mac_per_byte,
        intensity_mac_per_byte,
        tiled_input_intensity_mac_per_byte,
        bound,
    })
}

impl Roofline {
    /// The binding cycle count: the larger of the two bounds, when both are known.
    pub fn bound_cycles(&self) -> Option<u64> {
        self.dram_bound_cycles.map(|d| d.max(self.mac_bound_cycles))
    }

    /// Peak throughput in operations per second, counting one MAC as two operations.
    ///
    /// This is the `scaling-100tops.md` §2 definition: dense, peak, no sparsity and no
    /// sub-byte multiplier applied. `None` when the clock is not published.
    pub fn peak_ops_per_sec(&self, cfg: &AiIslandConfig) -> Option<u64> {
        let clock_hz = (cfg.clock_khz as u64).checked_mul(1_000)?;
        if clock_hz == 0 {
            return None;
        }
        self.macs_per_cycle_total
            .checked_mul(2)?
            .checked_mul(clock_hz)
    }

    /// MAC-array utilisation, as a percentage, against a cycle count measured elsewhere.
    ///
    /// The measurement must come from the design side — an RTL testbench or the island's own
    /// PMU counters. The package deliberately has no way to produce one itself, so a
    /// utilisation figure can never be self-referential.
    ///
    /// A low value means the shape spent its time in sequencing and memory rather than
    /// arithmetic, which is the quantity that decides whether widening the array would help.
    pub fn utilisation_percent(&self, measured_cycles: u64) -> Option<u64> {
        if measured_cycles == 0 {
            return None;
        }
        Some(self.mac_bound_cycles.saturating_mul(100) / measured_cycles)
    }
}

/// Emit the *shape-independent* machine properties as D2 counters.
///
/// These are properties of the part, not of a kernel: the blocking factor, the arithmetic
/// intensity every `T`-blocked GEMM has on it, the machine balance, and the §2 peak. They need
/// no GEMM shape, so they belong with the other island counters.
///
/// The balance is the number §4 calls "the single number to design against": every kernel with
/// intensity below it is bandwidth-bound on this part. It is omitted when the DRAM class is
/// unmeasured, which is the live part's state.
pub fn machine_counters(cfg: &AiIslandConfig) -> Vec<Counter> {
    let mut out = Vec::new();
    // A unit shape is a vehicle for the machine-level fields only. Every value read below is
    // shape-independent by construction -- MAC rate, blocking factor, `T / 2`, balance and the
    // §2 peak. The shape-dependent fields (traffic, bound cycles, `shape_fits_blocking`) are
    // deliberately *not* read here; a caller that wants them must state a real shape.
    let Some(r) = gemm(cfg, 1, 1, 1) else {
        return out;
    };
    let mut push = |name: &str, value: u64| {
        out.push(Counter {
            name: name.into(),
            value,
            fidelity: Fidelity::Modelled,
        });
    };
    push("ai.roofline.macs_per_cycle_total", r.macs_per_cycle_total);
    push("ai.roofline.blocking_t", r.blocking_t);
    push(
        "ai.roofline.tiled_input_intensity_mac_per_byte",
        r.tiled_input_intensity_mac_per_byte,
    );
    if let Some(v) = r.balance_mac_per_byte {
        push("ai.roofline.balance_mac_per_byte", v);
    }
    if let Some(v) = r.peak_ops_per_sec(cfg) {
        push("ai.roofline.peak_ops_per_sec", v);
    }
    out
}

/// Emit the bound as D2 counters.
///
/// Every counter is `Modelled`: the geometry is the design's own and the arithmetic is exact,
/// but the value is a bound rather than an observation, so it is not comparable for equality
/// with hardware. Unresolved quantities are omitted rather than reported as zero.
pub fn counters(r: &Roofline) -> Vec<Counter> {
    let mut out = Vec::new();
    let mut push = |name: &str, value: u64| {
        out.push(Counter {
            name: name.into(),
            value,
            fidelity: Fidelity::Modelled,
        });
    };
    push("ai.roofline.macs", r.macs);
    push("ai.roofline.macs_per_cycle_total", r.macs_per_cycle_total);
    push("ai.roofline.mac_bound_cycles", r.mac_bound_cycles);
    push("ai.roofline.blocking_t", r.blocking_t);
    push("ai.roofline.compulsory_read_bytes", r.compulsory_read_bytes);
    push("ai.roofline.tiled_read_bytes", r.tiled_read_bytes);
    push("ai.roofline.dram_read_bytes", r.dram_read_bytes);
    push("ai.roofline.dram_write_bytes", r.dram_write_bytes);
    push("ai.roofline.dram_bytes", r.dram_bytes);
    push(
        "ai.roofline.intensity_mac_per_byte",
        r.intensity_mac_per_byte,
    );
    push(
        "ai.roofline.tiled_input_intensity_mac_per_byte",
        r.tiled_input_intensity_mac_per_byte,
    );
    // A shape past the published blocking limit is rejected by the descriptor contract,
    // so the flag travels with the bound rather than being inferable from it.
    push(
        "ai.roofline.shape_fits_blocking",
        r.shape_fits_blocking as u64,
    );
    if let Some(v) = r.dram_bound_cycles {
        push("ai.roofline.dram_bound_cycles", v);
    }
    if let Some(v) = r.balance_mac_per_byte {
        push("ai.roofline.balance_mac_per_byte", v);
    }
    if let Some(v) = r.bound_cycles() {
        push("ai.roofline.bound_cycles", v);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The live island configuration, as published today.
    fn live() -> AiIslandConfig {
        AiIslandConfig {
            clusters: 1,
            macs_per_cycle: 256,
            clock_khz: 1_000_000,
            acc_tile_m: 256,
            acc_tile_n: 256,
            acc_tile_k: 256,
            dram_gbps: 0, // "not measured (I3)"
            ..Default::default()
        }
    }

    /// The throughput SKU of `scaling-100tops.md` §5.1.
    fn throughput_sku() -> AiIslandConfig {
        AiIslandConfig {
            clusters: 8,
            macs_per_cycle: 4096, // 64 x 64 PEs per cluster
            clock_khz: 1_500_000,
            acc_tile_m: 512,
            acc_tile_n: 512,
            acc_tile_k: 256,
            dram_gbps: 400,
            ..Default::default()
        }
    }

    /// The model must reproduce the plan's own worked numbers, or it is not a model of this
    /// machine. §4 states balance = 50e12 / 400e9 ~= 125 MAC per byte for the 8-cluster part.
    #[test]
    fn the_throughput_sku_reproduces_the_documented_machine_balance() {
        let cfg = throughput_sku();
        let r = gemm(&cfg, 4096, 4096, 4096).unwrap();

        assert_eq!(r.macs_per_cycle_total, 32_768);
        // §5.1: 32768 MAC/cycle at 1.5 GHz = 98.3 TOPS by the §2 definition.
        let ops = r.peak_ops_per_sec(&cfg).unwrap();
        assert_eq!(ops, 98_304_000_000_000);

        // §4: balance ~= 125 MAC per byte.
        let balance = r.balance_mac_per_byte.unwrap();
        assert!(
            (120..=125).contains(&balance),
            "balance {balance} should be about 125"
        );

        // §4 table: T = 512 gives 0.0039 input bytes/MAC, i.e. input intensity 256.
        assert_eq!(r.blocking_t, 512);
        assert_eq!(r.tiled_input_intensity_mac_per_byte, 256);

        // Intensity 256 is above balance 125, so this part is compute-bound at T = 512 --
        // which is why §5.1 can provision 400 GB/s against a 195 GB/s GEMM demand.
        assert_eq!(r.bound, Bound::Compute);

        // 4096 exceeds the 512 accumulator tile, so software must block this shape before
        // submitting it. The bound is still meaningful for the blocked whole, but the
        // descriptor contract will not take it in one piece.
        assert!(!r.shape_fits_blocking);
    }

    /// The reported read figure must be the larger of the compulsory floor and the tiled
    /// re-read model, or the bound is wrong at one end of the shape range.
    ///
    /// Using `2 / T` alone understates a shape smaller than `T`: a schedule that holds the
    /// whole problem on chip still has to read `m*k + k*n`. Using the floor alone understates
    /// a shape larger than `T`, which is the re-read trap §4.1 names.
    #[test]
    fn the_read_model_takes_the_larger_of_the_floor_and_the_reread() {
        let cfg = live(); // T = 256

        // Small shape: the compulsory floor dominates. `2 / T` would say 2,048 bytes.
        let small = gemm(&cfg, 64, 64, 64).unwrap();
        assert_eq!(small.compulsory_read_bytes, 64 * 64 + 64 * 64);
        assert_eq!(small.tiled_read_bytes, 262_144 * 2 / 256);
        assert_eq!(small.tiled_read_bytes, 2_048);
        assert_eq!(
            small.dram_read_bytes, 8_192,
            "a resident schedule still reads both operands once"
        );

        // At exactly m = n = k = T the two models coincide, which is why a test that only
        // looked at the maximal shape could not tell them apart.
        let square = gemm(&cfg, 256, 256, 256).unwrap();
        assert_eq!(square.compulsory_read_bytes, 131_072);
        assert_eq!(square.tiled_read_bytes, 131_072);
        assert_eq!(square.dram_read_bytes, 131_072);

        // Large shape: the re-read model dominates by an order of magnitude.
        let large = gemm(&cfg, 4096, 4096, 4096).unwrap();
        assert!(large.tiled_read_bytes > large.compulsory_read_bytes * 15);
        assert_eq!(large.dram_read_bytes, large.tiled_read_bytes);
    }

    /// The accumulator writeback is not negligible at the shapes this engine accepts, and
    /// the plan's §4 derivation counts input bytes only.
    ///
    /// At `m = n = k = T` the `s32` writeback is `4*T^2` against `2*T^2` of input, so it is
    /// *twice* the input traffic. Reporting only the §4 intensity would overstate the
    /// achievable throughput by 3x on this shape.
    #[test]
    fn the_accumulator_writeback_dominates_at_the_engines_own_shapes() {
        let r = gemm(&live(), 256, 256, 256).unwrap();
        assert_eq!(r.dram_read_bytes, 131_072);
        assert_eq!(r.dram_write_bytes, 4 * 256 * 256);
        assert_eq!(r.dram_write_bytes, 262_144);
        assert_eq!(
            r.dram_write_bytes,
            r.dram_read_bytes * 2,
            "s32 writeback is twice the int8 input traffic at m=n=k=T"
        );
        assert_eq!(r.dram_bytes, 393_216);

        // Total intensity is therefore a third of the input-only figure §4 quotes.
        assert_eq!(r.tiled_input_intensity_mac_per_byte, 128);
        assert_eq!(r.intensity_mac_per_byte, 42);
    }

    /// The descriptor contract bounds every dimension by its accumulator tile, and the
    /// acceptance shape in the plan is far outside it.
    ///
    /// The live GEMM unit states `m, n, k in [1, MaxDim]` and rejects anything larger, so
    /// the plan's `M = N = K = 4096` gate cannot be submitted as one descriptor at all --
    /// it needs host-side blocking into 16^3 pieces. The bound carries that fact rather
    /// than quietly describing a machine that would refuse the work.
    #[test]
    fn a_shape_past_the_blocking_limit_is_reported_as_not_fitting() {
        let cfg = live(); // acc_tile_* = 256

        assert!(gemm(&cfg, 256, 256, 256).unwrap().shape_fits_blocking);
        assert!(gemm(&cfg, 1, 1, 1).unwrap().shape_fits_blocking);

        // One dimension over the limit is enough.
        assert!(!gemm(&cfg, 257, 256, 256).unwrap().shape_fits_blocking);
        assert!(!gemm(&cfg, 256, 257, 256).unwrap().shape_fits_blocking);
        assert!(!gemm(&cfg, 256, 256, 257).unwrap().shape_fits_blocking);

        // The plan's own acceptance gate does not fit the live contract.
        assert!(!gemm(&cfg, 4096, 4096, 4096).unwrap().shape_fits_blocking);

        // And the flag reaches the counter stream, since it cannot be inferred from the
        // other numbers.
        let names: Vec<String> = counters(&gemm(&cfg, 4096, 4096, 4096).unwrap())
            .into_iter()
            .map(|c| c.name)
            .collect();
        assert!(names.contains(&"ai.roofline.shape_fits_blocking".to_string()));
    }

    /// At `T = 256` the machine sits on the knee: §4 asks for 391 GB/s against 400 provisioned.
    #[test]
    fn the_blocking_factor_alone_decides_input_intensity() {
        let mut cfg = throughput_sku();
        cfg.acc_tile_m = 256;
        cfg.acc_tile_n = 256;
        let r = gemm(&cfg, 4096, 4096, 4096).unwrap();

        // Input-only intensity is T/2 regardless of the shape -- the identity behind §4.
        assert_eq!(r.tiled_input_intensity_mac_per_byte, 128);
        let big = gemm(&cfg, 8192, 8192, 8192).unwrap();
        assert_eq!(
            big.tiled_input_intensity_mac_per_byte, 128,
            "input intensity is set by T only"
        );

        // Halving T halves it and tips a large shape over the balance point.
        cfg.acc_tile_m = 128;
        cfg.acc_tile_n = 128;
        let narrow = gemm(&cfg, 4096, 4096, 4096).unwrap();
        assert_eq!(narrow.tiled_input_intensity_mac_per_byte, 64);
        assert_eq!(
            narrow.bound,
            Bound::Bandwidth,
            "T=128 needs ~781 GB/s (§4) and cannot reach peak on 400"
        );
    }

    /// An unmeasured DRAM class has no roofline. This is the live part's actual state.
    #[test]
    fn an_unmeasured_dram_class_leaves_the_bandwidth_bound_unresolved() {
        let r = gemm(&live(), 256, 256, 256).unwrap();
        assert_eq!(r.dram_bound_cycles, None, "must not invent a bandwidth");
        assert_eq!(r.balance_mac_per_byte, None);
        assert_eq!(r.bound, Bound::Unresolved);
        assert_eq!(r.bound_cycles(), None);

        // The MAC side is still computable, and the counters omit the unresolved half
        // rather than reporting it as zero.
        let names: Vec<String> = counters(&r).into_iter().map(|c| c.name).collect();
        assert!(names.contains(&"ai.roofline.mac_bound_cycles".to_string()));
        assert!(!names.contains(&"ai.roofline.dram_bound_cycles".to_string()));
        assert!(!names.contains(&"ai.roofline.balance_mac_per_byte".to_string()));
    }

    /// A measured DRAM bandwidth closes the roofline even when the nameplate is zero.
    #[test]
    fn a_measured_dram_value_takes_precedence_over_the_nameplate() {
        let mut cfg = live();
        // Nameplate says unmeasured, but the cap window reports 320.5 GB/s from the last GEMM.
        cfg.dram_gbps = 0;
        cfg.measured_dram_gbps_x1000 = Some(320_500);

        let r = gemm(&cfg, 256, 256, 256).unwrap();
        assert!(
            r.dram_bound_cycles.is_some(),
            "measured bandwidth must resolve the DRAM bound"
        );
        assert!(r.balance_mac_per_byte.is_some());

        // The bound must be computable and finite.
        assert!(r.bound_cycles().is_some());
    }

    /// A measured value overrides a stale nameplate.
    #[test]
    fn a_measured_dram_value_overrides_a_nameplate() {
        let mut cfg = throughput_sku();
        // Nameplate claims 400 GB/s, but measurement says 320.5 GB/s.
        cfg.dram_gbps = 400;
        cfg.measured_dram_gbps_x1000 = Some(320_500);

        let r = gemm(&cfg, 256, 256, 256).unwrap();
        assert_eq!(r.bound, Bound::Bandwidth, "live shape is bandwidth-bound");
        let measured_cycles = r.dram_bound_cycles.unwrap();

        // The same shape with the nameplate 400 GB/s has fewer DRAM cycles (more bandwidth).
        cfg.measured_dram_gbps_x1000 = None;
        let r_nameplate = gemm(&cfg, 256, 256, 256).unwrap();
        let nameplate_cycles = r_nameplate.dram_bound_cycles.unwrap();
        assert!(measured_cycles > nameplate_cycles);

        // The bound uses the measured bandwidth: the MAC array needs more cycles at 320.5
        // GB/s than at 400 GB/s, so the measured bound is larger.
    }

    /// The known measured point: `corev_apu/ai_island/README.md` reports the 256-cubed
    /// directed GEMM at 83,705 cycles on the live single-cluster configuration.
    ///
    /// The MAC bound is 65,536 cycles, so about 78% of the time is arithmetic and the rest is
    /// sequencing and memory. That residue is what decides whether widening the array helps.
    #[test]
    fn the_measured_256_cubed_point_shows_the_sequencing_residue() {
        let r = gemm(&live(), 256, 256, 256).unwrap();
        assert_eq!(r.macs, 16_777_216);
        assert_eq!(r.mac_bound_cycles, 65_536);

        const MEASURED_256_CUBED_CYCLES: u64 = 83_705;
        let util = r.utilisation_percent(MEASURED_256_CUBED_CYCLES).unwrap();
        assert_eq!(util, 78);

        // Widening the array without touching the memory path does not remove the residue.
        // At the latency-SKU target of 8192 MAC/cycle the same shape needs 2,048 MAC cycles,
        // so if the ~18,000 non-MAC cycles stay, utilisation collapses -- the §11 failure mode.
        let mut wide = live();
        wide.macs_per_cycle = 8192;
        let rw = gemm(&wide, 256, 256, 256).unwrap();
        assert_eq!(rw.mac_bound_cycles, 2_048);
        let residue = MEASURED_256_CUBED_CYCLES - r.mac_bound_cycles;
        let projected = rw
            .utilisation_percent(rw.mac_bound_cycles + residue)
            .unwrap();
        assert!(
            projected < 15,
            "projected utilisation {projected}% should collapse, showing the trap"
        );
    }

    /// The live part is two orders of magnitude below the target, and the model says so.
    #[test]
    fn the_live_configuration_is_far_below_the_hundred_tops_definition() {
        let cfg = live();
        let r = gemm(&cfg, 256, 256, 256).unwrap();
        // 1 cluster x 256 MAC/cycle x 1 GHz x 2 ops = 512 GOPS.
        assert_eq!(r.peak_ops_per_sec(&cfg).unwrap(), 512_000_000_000);

        let target = throughput_sku();
        let rt = gemm(&target, 256, 256, 256).unwrap();
        let ratio = rt.peak_ops_per_sec(&target).unwrap() / r.peak_ops_per_sec(&cfg).unwrap();
        assert_eq!(ratio, 192, "128x MAC width and 1.5x clock");
    }

    /// Unresolved geometry yields no bound at all, rather than a guessed one.
    #[test]
    fn unpublished_geometry_yields_no_bound() {
        let mut cfg = live();
        cfg.macs_per_cycle = 0;
        assert!(gemm(&cfg, 8, 8, 8).is_none(), "no MAC rate, no bound");

        let mut cfg = live();
        cfg.acc_tile_m = 0;
        cfg.acc_tile_n = 0;
        assert!(
            gemm(&cfg, 8, 8, 8).is_none(),
            "no blocking factor, no bound"
        );
    }

    /// A bound is never comparable for equality with hardware.
    #[test]
    fn every_roofline_counter_is_modelled_not_exact() {
        let r = gemm(&throughput_sku(), 512, 512, 512).unwrap();
        let cs = counters(&r);
        assert!(!cs.is_empty());
        for c in cs {
            assert_eq!(c.fidelity, Fidelity::Modelled, "{}", c.name);
            assert!(!c.fidelity.comparable_for_equality(), "{}", c.name);
        }
    }
}
