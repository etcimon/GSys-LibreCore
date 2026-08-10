// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Pure ABI types for Xg6lcai T2 descriptors and completion words.
//!
//! Layout matches `g6lc_ai_desc_pkg` / `architecture/ai-matrix/isa-encoding.md` §7.
//! Little-endian host packing.

#![deny(unsafe_op_in_unsafe_fn)]

use thiserror::Error;

pub const DESC_BYTES: usize = 64;
pub const CONTRACT_VERSION: u16 = 1;

pub const OP_GEMM: u16 = 1;
pub const OP_CONV2D: u16 = 2;
pub const OP_LAYOUT: u16 = 3;
pub const OP_PREFETCH: u16 = 4;

pub const ST_OK: u16 = 0;
pub const ST_ERR: u16 = 1;
pub const ST_BAD_VER: u16 = 2;
pub const ST_BAD_OP: u16 = 3;
pub const ST_BAD_PTR: u16 = 4;
pub const ST_BAD_QID: u16 = 5;
pub const ST_DISABLED: u16 = 6;
pub const ST_WATCHDOG: u16 = 7;

/// `flags[2]` — request completion IRQ when sticky IRQ is wired.
pub const FLAG_IRQ: u32 = 1 << 2;

/// MMIO offsets (byte) relative to island base — island_p3_v1 / live README.
pub mod mmio {
    // CAP window (RO) — see g6lc_ai_cap_window
    pub const CAP_BASE: u16 = 0x0000;
    pub const CAP_VERSION: u16 = 0x0000;
    pub const CAP_CLUSTERS: u16 = 0x0004;
    pub const CAP_MACS_PER_CYCLE: u16 = 0x0008;
    pub const CAP_CLOCK_KHZ: u16 = 0x000C;
    pub const CAP_SRAM_BYTES: u16 = 0x0010;
    pub const CAP_ACC_TILE: u16 = 0x0014; // packed log2(K)|log2(N)|log2(M)
    pub const CAP_DRAM: u16 = 0x0018; // nameplate | meas milli-GB/s
    pub const CAP_QUEUES: u16 = 0x001C;
    pub const CAP_QOS: u16 = 0x0020;
    pub const CAP_WORK_QUANTUM: u16 = 0x0024;
    pub const CAP_DTYPE_MASK: u16 = 0x0028;

    pub const CTL: u16 = 0x0100;
    pub const STATUS: u16 = 0x0104;
    pub const DOORBELL: u16 = 0x0108;
    pub const DONE: u16 = 0x010C;
    pub const TICKET: u16 = 0x0110;
    pub const DSTATUS: u16 = 0x0114;
    pub const DESC_PTR_LO: u16 = 0x0118;
    pub const DESC_PTR_HI: u16 = 0x011C;
    pub const REG0: u16 = 0x0120;
    pub const DESC: u16 = 0x0140;

    // I3 PMU sticky last GEMM
    pub const PMU_R_BEATS: u16 = 0x0180;
    pub const PMU_W_BEATS: u16 = 0x0184;
    pub const PMU_CYCLES: u16 = 0x0188;
    pub const PMU_GBPS_X1000: u16 = 0x018C;

    pub const CTL_ENABLE: u32 = 1 << 0;
    pub const CTL_WR_CPL_EN: u32 = 1 << 1;
    pub const DOORBELL_FETCH: u32 = 1 << 31;
}

/// AccTile geometry from CAP_ACC_TILE (log2 fields x4 bits).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AccTile {
    pub m: u32,
    pub n: u32,
    pub k: u32,
}

impl AccTile {
    pub fn from_cap_word(w: u32) -> Self {
        let lm = w & 0xf;
        let ln = (w >> 4) & 0xf;
        let lk = (w >> 8) & 0xf;
        Self {
            m: 1u32 << lm,
            n: 1u32 << ln,
            k: 1u32 << lk,
        }
    }

    pub const ISLAND_P3_DEFAULT: Self = Self {
        m: 256,
        n: 256,
        k: 256,
    };

    pub fn fits(&self, m: u32, n: u32, k: u32) -> bool {
        m <= self.m && n <= self.n && k <= self.k
    }
}

/// CAP RO window fields used by software Caps.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CapRegs {
    pub version: u16,
    pub clusters: u32,
    pub macs_per_cycle: u32,
    pub clock_khz: u32,
    pub sram_bytes: u32,
    pub acc_tile: AccTile,
    pub dram_nameplate_gbps: u16,
    pub dram_meas_milli_gbps: u16,
    pub queues: u16,
    pub queue_depth: u16,
    pub dtype_mask: u16,
}

impl CapRegs {
    pub fn from_words(w: &[u32]) -> Option<Self> {
        if w.len() < 11 {
            return None;
        }
        let dram = w[6];
        let q = w[7];
        Some(Self {
            version: (w[0] & 0xffff) as u16,
            clusters: w[1],
            macs_per_cycle: w[2],
            clock_khz: w[3],
            sram_bytes: w[4],
            acc_tile: AccTile::from_cap_word(w[5]),
            dram_nameplate_gbps: (dram & 0xffff) as u16,
            dram_meas_milli_gbps: ((dram >> 16) & 0xffff) as u16,
            queues: (q & 0xffff) as u16,
            queue_depth: ((q >> 16) & 0xffff) as u16,
            dtype_mask: (w[10] & 0xffff) as u16,
        })
    }

    /// Synthetic CAP matching live AiIslandLatencyDefault shape (AccTile/Macs=256).
    pub fn island_p3_sim_default() -> Self {
        let acc_w = 8u32 | (8 << 4) | (8 << 8);
        Self {
            version: 1,
            clusters: 1,
            macs_per_cycle: 256,
            clock_khz: 1000,
            sram_bytes: 8 * 1024 * 1024,
            acc_tile: AccTile::from_cap_word(acc_w),
            dram_nameplate_gbps: 0,
            dram_meas_milli_gbps: 0,
            queues: 1,
            queue_depth: 4,
            dtype_mask: 0x0001,
        }
    }
}

/// Sticky last-GEMM PMU (MMIO 0x180-0x18C).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct PmuSnapshot {
    pub r_beats: u32,
    pub w_beats: u32,
    pub cycles: u32,
    pub gbps_x1000: u32,
}

impl PmuSnapshot {
    pub fn from_words(r: u32, w: u32, cy: u32, gbps: u32) -> Self {
        Self {
            r_beats: r,
            w_beats: w,
            cycles: cy,
            gbps_x1000: gbps,
        }
    }
}

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum AbiError {
    #[error("buffer length {got} != {DESC_BYTES}")]
    BadDescLen { got: usize },
}

/// Software view of the 64-byte T2 descriptor (host endian field access).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Desc64 {
    pub version: u16,
    pub op: u16,
    pub flags: u32,
    pub m: u32,
    pub n: u32,
    pub k: u32,
    /// `lda | (ldb << 16)`
    pub ld_ab: u32,
    pub ptr_a: u64,
    pub ptr_b: u64,
    pub ptr_c: u64,
    pub ptr_scale: u64,
    pub ptr_done: u64,
}

impl Default for Desc64 {
    fn default() -> Self {
        Self {
            version: CONTRACT_VERSION,
            op: OP_GEMM,
            flags: 0,
            m: 0,
            n: 0,
            k: 0,
            ld_ab: 0,
            ptr_a: 0,
            ptr_b: 0,
            ptr_c: 0,
            ptr_scale: 0,
            ptr_done: 0,
        }
    }
}

impl Desc64 {
    pub fn gemm(m: u32, n: u32, k: u32) -> Self {
        let mut d = Self::default();
        d.op = OP_GEMM;
        d.m = m;
        d.n = n;
        d.k = k;
        d.ld_ab = k | (n << 16); // lda=k (row-major A[m,k]), ldb=n (B[k,n] stored as k×n)
        d
    }

    pub fn with_ptrs(mut self, a: u64, b: u64, c: u64, done: u64) -> Self {
        self.ptr_a = a;
        self.ptr_b = b;
        self.ptr_c = c;
        self.ptr_done = done;
        self
    }

    pub fn with_irq(mut self, en: bool) -> Self {
        if en {
            self.flags |= FLAG_IRQ;
        } else {
            self.flags &= !FLAG_IRQ;
        }
        self
    }

    pub fn irq(&self) -> bool {
        (self.flags & FLAG_IRQ) != 0
    }

    pub fn lda(&self) -> u32 {
        self.ld_ab & 0xffff
    }

    pub fn ldb(&self) -> u32 {
        self.ld_ab >> 16
    }

    /// Pack to little-endian 64-byte image (matches `desc_to_bits` field placement).
    pub fn pack(&self) -> [u8; DESC_BYTES] {
        let mut b = [0u8; DESC_BYTES];
        put_u16(&mut b, 0x00, self.version);
        put_u16(&mut b, 0x02, self.op);
        put_u32(&mut b, 0x04, self.flags);
        put_u32(&mut b, 0x08, self.m);
        put_u32(&mut b, 0x0c, self.n);
        put_u32(&mut b, 0x10, self.k);
        put_u32(&mut b, 0x14, self.ld_ab);
        put_u64(&mut b, 0x18, self.ptr_a);
        put_u64(&mut b, 0x20, self.ptr_b);
        put_u64(&mut b, 0x28, self.ptr_c);
        put_u64(&mut b, 0x30, self.ptr_scale);
        put_u64(&mut b, 0x38, self.ptr_done);
        b
    }

    pub fn unpack(bytes: &[u8]) -> Result<Self, AbiError> {
        if bytes.len() != DESC_BYTES {
            return Err(AbiError::BadDescLen { got: bytes.len() });
        }
        Ok(Self {
            version: get_u16(bytes, 0x00),
            op: get_u16(bytes, 0x02),
            flags: get_u32(bytes, 0x04),
            m: get_u32(bytes, 0x08),
            n: get_u32(bytes, 0x0c),
            k: get_u32(bytes, 0x10),
            ld_ab: get_u32(bytes, 0x14),
            ptr_a: get_u64(bytes, 0x18),
            ptr_b: get_u64(bytes, 0x20),
            ptr_c: get_u64(bytes, 0x28),
            ptr_scale: get_u64(bytes, 0x30),
            ptr_done: get_u64(bytes, 0x38),
        })
    }
}

/// Completion word: ticket in [31:0], status in [47:32], reserved [63:48].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Completion {
    pub ticket: u32,
    pub status: u16,
}

impl Completion {
    pub fn make(ticket: u32, status: u16) -> u64 {
        (u64::from(status) << 32) | u64::from(ticket)
    }

    pub fn from_u64(w: u64) -> Self {
        Self {
            ticket: w as u32,
            status: ((w >> 32) & 0xffff) as u16,
        }
    }

    pub fn ok(ticket: u32) -> Self {
        Self {
            ticket,
            status: ST_OK,
        }
    }

    pub fn is_ok(self) -> bool {
        self.status == ST_OK
    }
}

fn put_u16(b: &mut [u8], off: usize, v: u16) {
    b[off..off + 2].copy_from_slice(&v.to_le_bytes());
}
fn put_u32(b: &mut [u8], off: usize, v: u32) {
    b[off..off + 4].copy_from_slice(&v.to_le_bytes());
}
fn put_u64(b: &mut [u8], off: usize, v: u64) {
    b[off..off + 8].copy_from_slice(&v.to_le_bytes());
}
fn get_u16(b: &[u8], off: usize) -> u16 {
    u16::from_le_bytes(b[off..off + 2].try_into().unwrap())
}
fn get_u32(b: &[u8], off: usize) -> u32 {
    u32::from_le_bytes(b[off..off + 4].try_into().unwrap())
}
fn get_u64(b: &[u8], off: usize) -> u64 {
    u64::from_le_bytes(b[off..off + 8].try_into().unwrap())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pack_roundtrip() {
        let d = Desc64::gemm(8, 8, 8)
            .with_ptrs(0x8001_0000, 0x8001_1000, 0x8001_2000, 0x8001_3000)
            .with_irq(true);
        let b = d.pack();
        assert_eq!(b.len(), 64);
        let u = Desc64::unpack(&b).unwrap();
        assert_eq!(u, d);
        assert_eq!(get_u16(&b, 0), CONTRACT_VERSION);
        assert_eq!(get_u16(&b, 2), OP_GEMM);
        assert_eq!(get_u32(&b, 4) & FLAG_IRQ, FLAG_IRQ);
        assert_eq!(get_u64(&b, 0x38), 0x8001_3000);
    }

    #[test]
    fn completion_word() {
        let w = Completion::make(9, ST_OK);
        assert_eq!(w, 9);
        let c = Completion::from_u64(w);
        assert!(c.is_ok());
        assert_eq!(c.ticket, 9);
        let w2 = Completion::make(1, ST_BAD_PTR);
        assert_eq!(Completion::from_u64(w2).status, ST_BAD_PTR);
    }

    /// Golden: version=1 op=1 flags=0 m=n=k=8 ld_ab=0x00080008
    /// ptrs A/B/C/done as in ai_irq style.
    #[test]
    fn golden_header_bytes() {
        let d = Desc64 {
            version: 1,
            op: OP_GEMM,
            flags: 0,
            m: 8,
            n: 8,
            k: 8,
            ld_ab: 0x0008_0008,
            ptr_a: 0x8001_0000,
            ptr_b: 0x8001_1000,
            ptr_c: 0x8001_2000,
            ptr_scale: 0,
            ptr_done: 0x8001_3000,
        };
        let b = d.pack();
        assert_eq!(&b[0..4], &[1, 0, 1, 0]); // ver=1, op=1
        assert_eq!(&b[8..12], &[8, 0, 0, 0]); // m
        assert_eq!(&b[0x14..0x18], &[0x08, 0x00, 0x08, 0x00]); // ld_ab LE
    }

    #[test]
    fn cap_acc_tile_256() {
        let w = 8u32 | (8 << 4) | (8 << 8);
        let t = AccTile::from_cap_word(w);
        assert_eq!(t, AccTile::ISLAND_P3_DEFAULT);
        assert!(t.fits(256, 256, 256));
        assert!(!t.fits(257, 1, 1));
        let caps = CapRegs::island_p3_sim_default();
        assert_eq!(caps.macs_per_cycle, 256);
        assert_eq!(caps.acc_tile.m, 256);
        assert_eq!(mmio::PMU_R_BEATS, 0x180);
        assert_eq!(mmio::CAP_MACS_PER_CYCLE, 0x08);
    }

    #[test]
    fn pmu_snapshot() {
        let p = PmuSnapshot::from_words(100, 50, 83705, 12);
        assert_eq!(p.cycles, 83705);
    }
}
