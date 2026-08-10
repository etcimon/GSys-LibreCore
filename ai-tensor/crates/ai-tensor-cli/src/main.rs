// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

use ai_tensor_abi::{Completion, Desc64, DESC_BYTES};
use ai_tensor_rt::{
    probe_cap_regs, run_builtin_suite, run_external_cosim_checks, run_gemm_s8, run_gemm_s8_auto,
    run_gemm_s8_stream, run_gemm_s8_stream_with_policy, seed_cap_island_p3, soak_irq_wait,
    soak_multi_queue, Device, IrqContract, MappedWindow, MmioDevice, Profile, SimDevice,
    WaitPolicy,
};
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
    Doctor {
        #[arg(long)]
        profile: Option<PathBuf>,
    },
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
        /// Set desc FLAG_IRQ and print irq_pending around poll
        #[arg(long, default_value_t = false)]
        irq: bool,
    },
    /// Probe CAP through a file-backed MappedWindow (seeded island_p3)
    ProbeMapped {
        #[arg(long)]
        file: Option<PathBuf>,
    },
    /// Hex-dump unpack of a 64-byte descriptor file
    Unpack {
        path: PathBuf,
    },
    /// Run package-local cosim goldens (sim + SoftIsland)
    GoldenCheck,
    /// Auto-tile GEMM (dims may exceed AccTile) — multi-tile desc stream
    AutoGemm {
        #[arg(long, default_value_t = 4)]
        m: u32,
        #[arg(long, default_value_t = 4)]
        n: u32,
        #[arg(long, default_value_t = 4)]
        k: u32,
        #[arg(long, default_value_t = 1)]
        ticket: u32,
    },
    /// Explicit multi-tile desc stream (zero-copy A/B, sequential tickets)
    StreamGemm {
        #[arg(long, default_value_t = 4)]
        m: u32,
        #[arg(long, default_value_t = 4)]
        n: u32,
        #[arg(long, default_value_t = 4)]
        k: u32,
        #[arg(long, default_value_t = 1)]
        ticket: u32,
        #[arg(long, default_value = "sim")]
        backend: String,
    },
    /// Multi-queue region isolation + IRQ/DMA wait-policy soak
    QueueSoak {
        #[arg(long, default_value = "sim")]
        backend: String,
    },
    /// Soft IRQ claim soak (PLIC discipline model; FLAG_IRQ + claim_done)
    IrqSoak {
        #[arg(long, default_value = "sim")]
        backend: String,
    },
    /// Stream GEMM with wait policy: poll | irq | dma
    StreamPolicy {
        #[arg(long, default_value_t = 4)]
        m: u32,
        #[arg(long, default_value_t = 4)]
        n: u32,
        #[arg(long, default_value_t = 4)]
        k: u32,
        #[arg(long, default_value = "poll")]
        policy: String,
        #[arg(long, default_value = "sim")]
        backend: String,
    },
}

fn main() {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Doctor { profile } => {
            println!("ai-tensor 0.1.0");
            println!("default_profile=sim-v0");
            println!("backends=sim,mmio-soft,mapped-file (linux-uio: feature linux-mmio)");
            println!("abi_rev=0.1.0");
            println!("desc_bytes={DESC_BYTES}");
            let mut dev = MmioDevice::new();
            let c = dev.probe_caps();
            println!(
                "soft_cap.acc_tile={}x{}x{} macs={} noc={}",
                c.acc_tile.m, c.acc_tile.n, c.acc_tile.k, c.macs_per_cycle, c.noc_width
            );
            if let Some(p) = profile {
                let pr = Profile::load_file(&p).expect("profile");
                println!(
                    "profile id={} backend={} mmio_base={:?} plic={:?} features={:?}",
                    pr.id, pr.backend, pr.mmio_base, pr.plic_source, pr.features
                );
            }
            let irq = IrqContract::island_p3_variane();
            println!(
                "irq_contract plic={} clear_before_complete={} notes={}",
                irq.plic_source, irq.clear_before_plic_complete, irq.notes
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
        Cmd::MmioGemm {
            m,
            n,
            k,
            ticket,
            irq,
        } => {
            let (a, b) = pattern_ab(m, n, k);
            let mut dev = MmioDevice::new();
            dev.probe_caps();
            if irq {
                // use manual path for FLAG_IRQ
                use ai_tensor_rt::{Region, Device as _};
                dev.enable(true);
                dev.set_wr_cpl_en(true);
                let need_a = (m * k) as usize;
                let need_b = (k * n) as usize;
                let need_c = (m * n) as usize;
                let pa = dev.alloc(need_a).unwrap();
                let pb = dev.alloc(need_b).unwrap();
                let pc = dev.alloc(need_c * 4).unwrap();
                let pd = dev.alloc(8).unwrap();
                dev.program_region(
                    0,
                    Region {
                        base: 0x1000,
                        limit: 0x1000 + (1 << 24),
                        read: true,
                        write: true,
                    },
                )
                .unwrap();
                let ab: Vec<u8> = a.iter().map(|x| *x as u8).collect();
                let bb: Vec<u8> = b.iter().map(|x| *x as u8).collect();
                dev.write_mem(pa, &ab).unwrap();
                dev.write_mem(pb, &bb).unwrap();
                let d = Desc64::gemm(m, n, k)
                    .with_ptrs(pa, pb, pc, pd)
                    .with_irq(true);
                dev.submit(0, ticket, &d).unwrap();
                println!("irq_pending_after_submit={}", dev.irq_pending());
                let comp = dev.wait(ticket).unwrap();
                println!("irq_pending_after_poll={}", dev.irq_pending());
                let mut raw = vec![0u8; need_c * 4];
                dev.read_mem(pc, &mut raw).unwrap();
                let c: Vec<i32> = raw
                    .chunks(4)
                    .map(|ch| i32::from_le_bytes(ch.try_into().unwrap()))
                    .collect();
                print_result(&c, &comp, "mmio-soft-irq");
            } else {
                let (c, comp) = run_gemm_s8(&mut dev, m, n, k, &a, &b, ticket).expect("gemm");
                print_result(&c, &comp, "mmio-soft");
            }
            let p = dev.pmu();
            println!(
                "pmu r_beats={} w_beats={} cycles={}",
                p.r_beats, p.w_beats, p.cycles
            );
        }
        Cmd::ProbeMapped { file } => {
            let mut w = if let Some(path) = file {
                MappedWindow::open_file(&path, MappedWindow::ISLAND_WINDOW).expect("map file")
            } else {
                MappedWindow::zeros(MappedWindow::ISLAND_WINDOW)
            };
            seed_cap_island_p3(&mut w);
            let cap = probe_cap_regs(&mut w);
            println!(
                "mapped_cap version={} macs={} tile={}x{}x{}",
                cap.version,
                cap.macs_per_cycle,
                cap.acc_tile.m,
                cap.acc_tile.n,
                cap.acc_tile.k
            );
        }
        Cmd::Unpack { path } => {
            let bytes = std::fs::read(path).expect("read");
            let d = Desc64::unpack(&bytes).expect("unpack");
            println!("{d:?}");
        }
        Cmd::GoldenCheck => {
            let n = run_builtin_suite().expect("golden suite");
            println!("golden_ok count={n} backends=sim,mmio-soft");
            match run_external_cosim_checks() {
                None => {
                    println!(
                        "external_cosim=skipped (set AI_TENSOR_COSIM_CMD=python3 tools/cosim_harness.py)"
                    );
                }
                Some(Ok((ping, job))) => {
                    println!("external_cosim_ping={ping}");
                    println!("external_cosim_job={job}");
                }
                Some(Err(e)) => {
                    eprintln!("external_cosim_err={e}");
                    std::process::exit(1);
                }
            }
        }
        Cmd::AutoGemm { m, n, k, ticket } => {
            let (a, b) = pattern_ab(m, n, k);
            let mut dev = MmioDevice::new();
            dev.probe_caps();
            let (c, comp, tiles) =
                run_gemm_s8_auto(&mut dev, m, n, k, &a, &b, ticket).expect("auto");
            println!(
                "backend=mmio-auto tiles={} ticket={} status={} c00={}",
                tiles, comp.ticket, comp.status, c[0]
            );
        }
        Cmd::StreamGemm {
            m,
            n,
            k,
            ticket,
            backend,
        } => {
            let (a, b) = pattern_ab(m, n, k);
            let be = backend.to_lowercase();
            let (c, comp, tiles) = if be == "sim" {
                let mut dev = SimDevice::new();
                run_gemm_s8_stream(&mut dev, m, n, k, &a, &b, ticket).expect("stream")
            } else {
                let mut dev = MmioDevice::new();
                dev.probe_caps();
                run_gemm_s8_stream(&mut dev, m, n, k, &a, &b, ticket).expect("stream")
            };
            println!(
                "backend=stream-{be} tiles={} ticket={} status={} c00={} c_last={}",
                tiles,
                comp.ticket,
                comp.status,
                c[0],
                c[c.len() - 1]
            );
        }
        Cmd::QueueSoak { backend } => {
            let be = backend.to_lowercase();
            let n = if be == "sim" {
                let mut dev = SimDevice::new();
                soak_multi_queue(&mut dev).expect("queue soak")
            } else {
                let mut dev = MmioDevice::new();
                dev.probe_caps();
                soak_multi_queue(&mut dev).expect("queue soak")
            };
            println!("queue_soak_ok backend={be} checks={n}");
        }
        Cmd::IrqSoak { backend } => {
            let be = backend.to_lowercase();
            if be == "sim" {
                let mut dev = SimDevice::new();
                soak_irq_wait(&mut dev).expect("irq soak");
            } else {
                let mut dev = MmioDevice::new();
                dev.probe_caps();
                soak_irq_wait(&mut dev).expect("irq soak");
            }
            let c = IrqContract::island_p3_variane();
            println!(
                "irq_soak_ok backend={be} plic={} mode=soft_sticky",
                c.plic_source
            );
        }
        Cmd::StreamPolicy {
            m,
            n,
            k,
            policy,
            backend,
        } => {
            let (a, b) = pattern_ab(m, n, k);
            let be = backend.to_lowercase();
            let pol = match policy.to_lowercase().as_str() {
                "irq" | "irq_then_poll" => WaitPolicy::IrqThenPoll,
                "dma" | "dma_then_claim" => WaitPolicy::DmaThenClaim {
                    ptr_done: 0, // filled per-job from plan
                    claim: true,
                },
                _ => WaitPolicy::Poll,
            };
            let (c, comp, tiles) = if be == "sim" {
                let mut dev = SimDevice::new();
                run_gemm_s8_stream_with_policy(&mut dev, m, n, k, &a, &b, 1, pol).expect("stream")
            } else {
                let mut dev = MmioDevice::new();
                dev.probe_caps();
                run_gemm_s8_stream_with_policy(&mut dev, m, n, k, &a, &b, 1, pol).expect("stream")
            };
            println!(
                "backend=stream-{be} policy={policy} tiles={} ticket={} status={} c00={}",
                tiles, comp.ticket, comp.status, c[0]
            );
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
