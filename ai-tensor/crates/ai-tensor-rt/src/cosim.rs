// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Offline cosim goldens: package-local vectors that both SoftIsland and sim must match.
//!
//! Optional external harness: set `AI_TENSOR_COSIM_CMD` to a shell command that receives
//! a JSON job on stdin and prints a status line (see `tools/cosim_harness.py`).

use crate::{run_gemm_s8, run_gemm_s8_auto, Device, MmioDevice, RtError, SimDevice};
use ai_tensor_abi::{Completion, Desc64, ST_OK};
use std::io::Write;
use std::process::{Command, Stdio};

/// One offline golden vector (INT8 GEMM → i32).
#[derive(Debug, Clone)]
pub struct GoldenGemm {
    pub name: &'static str,
    pub m: u32,
    pub n: u32,
    pub k: u32,
    pub a: &'static [i8],
    pub b: &'static [i8],
    pub c: &'static [i32],
}

/// Built-in suite (keep in lockstep with `tools/cosim_harness.py` BUILTIN).
pub fn builtin_goldens() -> &'static [GoldenGemm] {
    &[
        GoldenGemm {
            name: "2x2_manual",
            m: 2,
            n: 2,
            k: 2,
            a: &[1, 2, 3, 4],
            b: &[5, 6, 7, 8],
            c: &[19, 22, 43, 50],
        },
        GoldenGemm {
            name: "1x1",
            m: 1,
            n: 1,
            k: 1,
            a: &[7],
            b: &[-3],
            c: &[-21],
        },
        GoldenGemm {
            name: "3x2x4_ones",
            m: 3,
            n: 2,
            k: 4,
            a: &[1; 12],
            b: &[1; 8],
            c: &[4, 4, 4, 4, 4, 4],
        },
        GoldenGemm {
            name: "2x3x2_mixed",
            m: 2,
            n: 3,
            k: 2,
            a: &[1, -1, 2, 0],
            b: &[3, 4, 5, -2, 1, 0],
            c: &[5, 3, 5, 6, 8, 10],
        },
    ]
}

pub fn check_device_against_golden<D: Device>(
    dev: &mut D,
    g: &GoldenGemm,
    ticket: u32,
) -> Result<(), RtError> {
    let (got, comp) = run_gemm_s8(dev, g.m, g.n, g.k, g.a, g.b, ticket)?;
    if comp.status != ST_OK {
        return Err(RtError::Msg(format!(
            "{}: status {}",
            g.name, comp.status
        )));
    }
    if got.as_slice() != g.c {
        return Err(RtError::Msg(format!(
            "{}: c mismatch got={got:?} exp={:?}",
            g.name, g.c
        )));
    }
    Ok(())
}

/// Run all built-in goldens on both sim and SoftIsland MMIO.
pub fn run_builtin_suite() -> Result<usize, RtError> {
    let mut n = 0usize;
    for (i, g) in builtin_goldens().iter().enumerate() {
        let mut sim = SimDevice::new();
        check_device_against_golden(&mut sim, g, 10 + i as u32)?;
        let mut mmio = MmioDevice::new();
        mmio.probe_caps();
        check_device_against_golden(&mut mmio, g, 20 + i as u32)?;
        n += 1;
    }
    // Cross-check auto-tile path (4x4 all-ones, tile fits default → 1 job)
    let a = vec![1i8; 16];
    let b = vec![1i8; 16];
    let mut sim = SimDevice::new();
    let (c, comp, tiles) = run_gemm_s8_auto(&mut sim, 4, 4, 4, &a, &b, 99)?;
    if comp.status != ST_OK || tiles != 1 || c.iter().any(|&x| x != 4) {
        return Err(RtError::Msg("auto_tile 4x4 ones failed".into()));
    }
    Ok(n)
}

/// Pack a golden as full JSON job (includes a/b/c_expect for external harness).
pub fn golden_job_json(g: &GoldenGemm) -> String {
    let a = join_i8(g.a);
    let b = join_i8(g.b);
    let c = join_i32(g.c);
    format!(
        r#"{{"op":"gemm_s8","name":"{}","m":{},"n":{},"k":{},"a":[{}],"b":[{}],"c_expect":[{}]}}"#,
        g.name, g.m, g.n, g.k, a, b, c
    )
}

fn join_i8(xs: &[i8]) -> String {
    xs.iter()
        .map(|x| x.to_string())
        .collect::<Vec<_>>()
        .join(",")
}

fn join_i32(xs: &[i32]) -> String {
    xs.iter()
        .map(|x| x.to_string())
        .collect::<Vec<_>>()
        .join(",")
}

fn run_external_cosim_stdin(stdin_json: &str) -> Result<String, RtError> {
    let cmd = std::env::var("AI_TENSOR_COSIM_CMD")
        .map_err(|_| RtError::Msg("AI_TENSOR_COSIM_CMD unset".into()))?;
    let mut child = Command::new("sh")
        .arg("-c")
        .arg(&cmd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| RtError::Msg(format!("cosim spawn: {e}")))?;
    if let Some(mut sin) = child.stdin.take() {
        writeln!(sin, "{stdin_json}").map_err(|e| RtError::Msg(format!("cosim stdin: {e}")))?;
    }
    let out = child
        .wait_with_output()
        .map_err(|e| RtError::Msg(format!("cosim wait: {e}")))?;
    if !out.status.success() {
        return Err(RtError::Msg(format!(
            "cosim exit {:?}: {}",
            out.status.code(),
            String::from_utf8_lossy(&out.stderr)
        )));
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// Optional: invoke external cosim command if `AI_TENSOR_COSIM_CMD` is set.
/// Command is not run in default CI. Returns None if env unset.
pub fn try_external_cosim_ping() -> Option<Result<String, RtError>> {
    if std::env::var("AI_TENSOR_COSIM_CMD").is_err() {
        return None;
    }
    Some(run_external_cosim_stdin(r#"{"ping":true}"#))
}

/// Optional: send first built-in golden as a full gemm job to the external harness.
pub fn try_external_cosim_job() -> Option<Result<String, RtError>> {
    if std::env::var("AI_TENSOR_COSIM_CMD").is_err() {
        return None;
    }
    let g = &builtin_goldens()[0];
    Some(run_external_cosim_stdin(&golden_job_json(g)))
}

/// Run external ping + one gemm job when harness env is set.
pub fn run_external_cosim_checks() -> Option<Result<(String, String), RtError>> {
    if std::env::var("AI_TENSOR_COSIM_CMD").is_err() {
        return None;
    }
    Some((|| {
        let ping = run_external_cosim_stdin(r#"{"ping":true}"#)?;
        if !ping.contains("pong") && !ping.contains("ok") {
            return Err(RtError::Msg(format!("cosim ping unexpected: {ping}")));
        }
        let job = run_external_cosim_stdin(&golden_job_json(&builtin_goldens()[0]))?;
        if !job.contains("status=0") {
            return Err(RtError::Msg(format!("cosim job not ok: {job}")));
        }
        Ok((ping, job))
    })())
}

/// Descriptor image golden: version/op/m/n/k packing (ABI lock).
pub fn check_desc_pack_golden() -> Result<(), RtError> {
    let d = Desc64::gemm(8, 8, 8).with_ptrs(0x8001_0000, 0x8001_1000, 0x8001_2000, 0x8001_3000);
    let b = d.pack();
    if b[0..4] != [1, 0, 1, 0] {
        return Err(RtError::Msg("desc header golden".into()));
    }
    if b[8..12] != [8, 0, 0, 0] {
        return Err(RtError::Msg("desc m golden".into()));
    }
    let _ = Completion::make(1, ST_OK);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builtin_sim_and_mmio() {
        let n = run_builtin_suite().expect("suite");
        assert_eq!(n, 4);
    }

    #[test]
    fn desc_pack() {
        check_desc_pack_golden().unwrap();
    }

    #[test]
    fn golden_job_json_shape() {
        let j = golden_job_json(&builtin_goldens()[0]);
        assert!(j.contains(r#""op":"gemm_s8""#));
        assert!(j.contains(r#""name":"2x2_manual""#));
        assert!(j.contains("c_expect"));
    }
}
