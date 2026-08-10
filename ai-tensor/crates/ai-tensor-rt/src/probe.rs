// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//! Host probe report (JSON-friendly, no serde required).

use crate::{Caps, IrqContract, Profile};
use ai_tensor_abi::PmuSnapshot;

/// Snapshot for host discovery / `cva6-build tensor doctor --json`.
#[derive(Debug, Clone)]
pub struct ProbeReport {
    pub package: &'static str,
    pub abi_rev: &'static str,
    pub profile_id: String,
    pub backend: String,
    pub wait_policy: String,
    pub submit_mode: String,
    pub mmio_base: Option<u64>,
    pub plic_source: Option<u32>,
    pub caps: Caps,
    pub pmu: PmuSnapshot,
    pub irq: IrqContract,
    pub features: Vec<String>,
}

impl ProbeReport {
    pub fn from_parts(
        profile: &Profile,
        caps: Caps,
        pmu: PmuSnapshot,
        backend_label: &str,
    ) -> Self {
        Self {
            package: "ai-tensor",
            abi_rev: "0.1.0",
            profile_id: profile.id.clone(),
            backend: backend_label.to_string(),
            wait_policy: profile.wait_policy.clone(),
            submit_mode: profile.submit_mode.clone(),
            mmio_base: profile.mmio_base,
            plic_source: profile.plic_source.or(Some(IrqContract::island_p3_variane().plic_source)),
            caps,
            pmu,
            irq: IrqContract::island_p3_variane(),
            features: profile.features.clone(),
        }
    }

    /// Minimal JSON (stable keys for host adapters).
    pub fn to_json(&self) -> String {
        let feats = self
            .features
            .iter()
            .map(|f| format!("\"{}\"", escape(f)))
            .collect::<Vec<_>>()
            .join(",");
        let mmio = match self.mmio_base {
            Some(b) => format!("\"0x{b:x}\""),
            None => "null".into(),
        };
        let plic = match self.plic_source {
            Some(p) => p.to_string(),
            None => "null".into(),
        };
        format!(
            concat!(
                "{{",
                "\"package\":\"{pkg}\",",
                "\"abi_rev\":\"{abi}\",",
                "\"profile_id\":\"{pid}\",",
                "\"backend\":\"{be}\",",
                "\"wait_policy\":\"{wp}\",",
                "\"submit_mode\":\"{sm}\",",
                "\"mmio_base\":{mmio},",
                "\"plic_source\":{plic},",
                "\"caps\":{{",
                "\"acc_tile_m\":{tm},\"acc_tile_n\":{tn},\"acc_tile_k\":{tk},",
                "\"macs_per_cycle\":{macs},\"noc_width\":{noc},",
                "\"clusters\":{cl},\"queues\":{q},\"queue_depth\":{qd}",
                "}},",
                "\"pmu\":{{\"r_beats\":{pr},\"w_beats\":{pw},\"cycles\":{pc},\"gbps_x1000\":{pg}}},",
                "\"irq\":{{\"plic_source\":{ip},\"clear_before_plic_complete\":{ic}}},",
                "\"features\":[{feats}]",
                "}}"
            ),
            pkg = self.package,
            abi = self.abi_rev,
            pid = escape(&self.profile_id),
            be = escape(&self.backend),
            wp = escape(&self.wait_policy),
            sm = escape(&self.submit_mode),
            mmio = mmio,
            plic = plic,
            tm = self.caps.acc_tile.m,
            tn = self.caps.acc_tile.n,
            tk = self.caps.acc_tile.k,
            macs = self.caps.macs_per_cycle,
            noc = self.caps.noc_width,
            cl = self.caps.clusters,
            q = self.caps.queues,
            qd = self.caps.queue_depth,
            pr = self.pmu.r_beats,
            pw = self.pmu.w_beats,
            pc = self.pmu.cycles,
            pg = self.pmu.gbps_x1000,
            ip = self.irq.plic_source,
            ic = if self.irq.clear_before_plic_complete {
                "true"
            } else {
                "false"
            },
            feats = feats,
        )
    }
}

fn escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Caps, Profile};
    use ai_tensor_abi::PmuSnapshot;

    #[test]
    fn json_shape() {
        let mut p = Profile::default();
        p.id = "sim-v0".into();
        p.wait_policy = "poll".into();
        p.submit_mode = "latch".into();
        p.features = vec!["op_gemm".into()];
        let r = ProbeReport::from_parts(&p, Caps::default(), PmuSnapshot::default(), "sim");
        let j = r.to_json();
        assert!(j.contains("\"package\":\"ai-tensor\""));
        assert!(j.contains("\"acc_tile_m\":"));
        assert!(j.contains("\"plic_source\":8"));
    }
}
