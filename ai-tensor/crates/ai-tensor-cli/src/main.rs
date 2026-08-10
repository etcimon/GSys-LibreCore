// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

use ai_tensor_abi::{Completion, Desc64, DESC_BYTES};
use ai_tensor_rt::{run_gemm_s8, SimDevice};
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
    /// Print package / profile info
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
    /// Run a tiny INT8 GEMM on the hostless sim
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
    /// Hex-dump unpack of a 64-byte descriptor file
    Unpack {
        path: PathBuf,
    },
}

fn main() {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Doctor => {
            println!("ai-tensor 0.1.0");
            println!("default_profile=sim-v0");
            println!("backend=sim");
            println!("abi_rev=0.1.0");
            println!("desc_bytes={DESC_BYTES}");
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
            let mut a = vec![1i8; (m * k) as usize];
            let mut b = vec![1i8; (k * n) as usize];
            // mild pattern
            for i in 0..a.len() {
                a[i] = ((i % 7) as i8) - 3;
            }
            for i in 0..b.len() {
                b[i] = ((i % 5) as i8) - 2;
            }
            let mut dev = SimDevice::new();
            let (c, comp) = run_gemm_s8(&mut dev, m, n, k, &a, &b, ticket).expect("gemm");
            println!(
                "ticket={} status={} c00={} c_last={}",
                comp.ticket,
                comp.status,
                c[0],
                c[c.len() - 1]
            );
            let word = Completion::make(comp.ticket, comp.status);
            println!("completion_word=0x{word:016x}");
        }
        Cmd::Unpack { path } => {
            let bytes = std::fs::read(path).expect("read");
            let d = Desc64::unpack(&bytes).expect("unpack");
            println!("{d:?}");
        }
    }
}
