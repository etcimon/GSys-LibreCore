// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

use ai_tensor_abi::{Completion, Desc64, DESC_BYTES};
use ai_tensor_rt::{run_gemm_s8, Device, MmioDevice, SimDevice};
use clap::{Parser, Subcommand};
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "ai-tensor", about = "Xg6lcai host tools (sim by default)")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Print package / profile / CAP pin info
    Doctor,
    /// Pack a minimal GEMM descriptor to hex
    PackGemm {
        #[arg(long, default_value_t = 8)]
        m: u32,
        #[arg(long, default_value_t = 8)]
        n: u32,
        #[arg(long, default_value_t = 8)]
        k: u32,
    },
    /// Run INT8 GEMM on hostless sim (direct, no MMIO)
    SimGemm {
        #[arg(long, default_value_t = 4)]
        m: u32,
        #[arg(long, default_value_t = 4)]
        n: u32,
        #[arg(long, default_value_t = 4)]
        k: u32,
        #[arg(long, default_value_t = 1)]
        ticket: u32,
    },
    /// Run INT8 GEMM via SoftIsland MMIO protocol (CAP/desc/doorbell/PMU)
    MmioGemm {
        #[arg(long, default_value_t = 4)]
        m: u32,
        #[arg(long, default_value_t = 4)]
        n: u32,
        #[arg(long, default_value_t = 4)]
        k: u32,
        #[arg(long, default_value_t = 1)]
        ticket: u32,
    },
    /// Hex-dump unpack of a 64-byte descriptor file
    Unpack {
        path: PathBuf,
    },
}

fn main() {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Doctor => {
            let mut dev = MmioDevice::new();
            let c = dev.probe_caps();
            println!("ai-tensor 0.1.0");
            println!("default_profile=sim-v0");
            println!("backends=sim,mmio-soft (linux-uio: feature linux-mmio stub)");
            println!("abi_rev=0.1.0");
            println!("desc_bytes={DESC_BYTES}");
            println!(
                "cap.acc_tile={}x{}x{} macs_per_cycle={} noc_width={}",
                c.acc_tile.m, c.acc_tile.n, c.acc_tile.k, c.macs_per_cycle, c.noc_width
            );
        }
        Cmd::PackGemm { m, n, k } => {
            let d = Desc64::gemm(m, n, k).with_ptrs(0x1000, 0x2000, 0x3000, 0x4000);
            let b = d.pack();
            print!("desc_hex=");
            for x in b {
                print!("{x:02x}");
            }
            println!();
        }
        Cmd::SimGemm { m, n, k, ticket } => {
            let (a, b) = pattern_ab(m, n, k);
            let mut dev = SimDevice::new();
            let (c, comp) = run_gemm_s8(&mut dev, m, n, k, &a, &b, ticket).expect("gemm");
            print_result(&c, &comp, "sim");
        }
        Cmd::MmioGemm { m, n, k, ticket } => {
            let (a, b) = pattern_ab(m, n, k);
            let mut dev = MmioDevice::new();
            dev.probe_caps();
            let (c, comp) = run_gemm_s8(&mut dev, m, n, k, &a, &b, ticket).expect("gemm");
            let p = dev.pmu();
            print_result(&c, &comp, "mmio-soft");
            println!(
                "pmu r_beats={} w_beats={} cycles={}",
                p.r_beats, p.w_beats, p.cycles
            );
        }
        Cmd::Unpack { path } => {
            let bytes = std::fs::read(path).expect("read");
            let d = Desc64::unpack(&bytes).expect("unpack");
            println!("{d:?}");
        }
    }
}

fn pattern_ab(m: u32, n: u32, k: u32) -> (Vec<i8>, Vec<i8>) {
    let mut a = vec![1i8; (m * k) as usize];
    let mut b = vec![1i8; (k * n) as usize];
    for i in 0..a.len() {
        a[i] = ((i % 7) as i8) - 3;
    }
    for i in 0..b.len() {
        b[i] = ((i % 5) as i8) - 2;
    }
    (a, b)
}

fn print_result(c: &[i32], comp: &Completion, backend: &str) {
    println!(
        "backend={backend} ticket={} status={} c00={} c_last={}",
        comp.ticket,
        comp.status,
        c[0],
        c[c.len() - 1]
    );
    let word = Completion::make(comp.ticket, comp.status);
    println!("completion_word=0x{word:016x}");
}
