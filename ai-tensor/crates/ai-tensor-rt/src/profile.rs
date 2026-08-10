// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Minimal profile TOML subset (no serde required).

use crate::{RtError, SubmitMode, WaitPolicy};
use std::collections::HashMap;
use std::path::Path;

#[derive(Debug, Clone, Default)]
pub struct Profile {
    pub id: String,
    pub backend: String,
    pub noc_width: u32,
    pub acc_tile_m: u32,
    pub acc_tile_n: u32,
    pub acc_tile_k: u32,
    pub macs_per_cycle: u32,
    pub mmio_base: Option<u64>,
    pub plic_source: Option<u32>,
    /// poll | irq | dma — host wait preference (see WaitPolicy).
    pub wait_policy: String,
    /// latch | fetch — doorbell path preference.
    pub submit_mode: String,
    pub features: Vec<String>,
    pub raw: HashMap<String, String>,
}

impl Profile {
    pub fn load_file(path: &Path) -> Result<Self, RtError> {
        let text = std::fs::read_to_string(path)
            .map_err(|e| RtError::Msg(format!("profile read {}: {e}", path.display())))?;
        Self::parse(&text)
    }

    pub fn parse(text: &str) -> Result<Self, RtError> {
        let mut p = Profile {
            noc_width: 64,
            acc_tile_m: 256,
            acc_tile_n: 256,
            acc_tile_k: 256,
            macs_per_cycle: 256,
            backend: "sim".into(),
            wait_policy: "poll".into(),
            submit_mode: "latch".into(),
            ..Default::default()
        };
        let mut in_features = false;
        for line in text.lines() {
            let line = line.split('#').next().unwrap_or("").trim();
            if line.is_empty() {
                continue;
            }
            if line.starts_with("features") {
                in_features = true;
                if let Some(rest) = line.split('[').nth(1) {
                    let body = rest.split(']').next().unwrap_or("");
                    for item in body.split(',') {
                        let s = item.trim().trim_matches('"').trim_matches('\'');
                        if !s.is_empty() {
                            p.features.push(s.to_string());
                        }
                    }
                }
                if line.contains(']') {
                    in_features = false;
                }
                continue;
            }
            if in_features {
                if line.contains(']') {
                    in_features = false;
                    let s = line
                        .replace(']', "")
                        .trim()
                        .trim_matches(',')
                        .trim()
                        .trim_matches('"')
                        .trim_matches('\'')
                        .to_string();
                    if !s.is_empty() {
                        p.features.push(s);
                    }
                    continue;
                }
                let s = line
                    .trim()
                    .trim_matches(',')
                    .trim()
                    .trim_matches('"')
                    .trim_matches('\'');
                if !s.is_empty() {
                    p.features.push(s.to_string());
                }
                continue;
            }
            if let Some((k, v)) = line.split_once('=') {
                let k = k.trim().to_string();
                let v = v.trim().trim_matches('"').trim_matches('\'').to_string();
                match k.as_str() {
                    "id" => p.id = v.clone(),
                    "backend" => p.backend = v.clone(),
                    "noc_width" => p.noc_width = v.parse().unwrap_or(64),
                    "acc_tile_m" => p.acc_tile_m = v.parse().unwrap_or(256),
                    "acc_tile_n" => p.acc_tile_n = v.parse().unwrap_or(256),
                    "acc_tile_k" => p.acc_tile_k = v.parse().unwrap_or(256),
                    "macs_per_cycle" => p.macs_per_cycle = v.parse().unwrap_or(256),
                    "mmio_base" => p.mmio_base = parse_u64(&v),
                    "plic_source" => p.plic_source = v.parse().ok(),
                    "wait_policy" => p.wait_policy = v.clone(),
                    "submit_mode" => p.submit_mode = v.clone(),
                    _ => {}
                }
                p.raw.insert(k, v);
            }
        }
        Ok(p)
    }
}

fn parse_u64(s: &str) -> Option<u64> {
    let s = s.trim();
    if let Some(h) = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
        u64::from_str_radix(h, 16).ok()
    } else {
        s.parse().ok()
    }
}

impl Profile {
    /// Map profile string to runtime WaitPolicy (dma needs ptr filled by caller).
    pub fn to_wait_policy(&self) -> WaitPolicy {
        match self.wait_policy.to_ascii_lowercase().as_str() {
            "irq" | "irq_then_poll" => WaitPolicy::IrqThenPoll,
            "dma" | "dma_then_claim" => WaitPolicy::DmaThenClaim {
                ptr_done: 0,
                claim: true,
            },
            "claim" | "claim_only" => WaitPolicy::ClaimOnly,
            _ => WaitPolicy::Poll,
        }
    }

    pub fn to_submit_mode(&self) -> SubmitMode {
        SubmitMode::from_str_loose(&self.submit_mode)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_island_p3() {
        let t = r#"
id = "island-p3-v1"
backend = "linux-uio"
noc_width = 64
acc_tile_m = 256
mmio_base = "0x40000000"
plic_source = 8
features = [
  "t2_desc_v1",
  "pmu_v1",
]
"#;
        let p = Profile::parse(t).unwrap();
        assert_eq!(p.id, "island-p3-v1");
        assert_eq!(p.mmio_base, Some(0x4000_0000));
        assert_eq!(p.plic_source, Some(8));
        assert!(p.features.iter().any(|f| f == "pmu_v1"));
    }
}
