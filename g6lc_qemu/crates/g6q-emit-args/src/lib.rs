// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! `g6q-emit-args` — backend **B0**, the stock-QEMU driver.
//!
//! B0 emits **no code at all**. It composes an invocation of an unmodified
//! `qemu-system-riscv64` and, just as importantly, a **capability delta report** listing
//! everything about the design that a stock generic machine cannot express
//! ([`architecture/EMIT.md`] §2).
//!
//! The delta is the deliverable, not a footnote. A stock machine has a different memory
//! map, different interrupt geometry, no vendor devices, and no notion of the design's
//! microarchitectural parameters. Stating that precisely is what makes an early boot
//! honest rather than misleading.
//!
//! # Modules
//!
//! * [`invoke`] — the argument vector, processor properties and profile checks
//!
//! The delta computation lives at the crate root because it is the part with the
//! correctness question in it.
//!
//! [`architecture/EMIT.md`]: ../../../architecture/EMIT.md

#![forbid(unsafe_code)]

pub mod invoke;

pub use invoke::{
    build_argv, check_profile, cpu_argument, BootOptions, Firmware, Icount, StockTarget,
};

use g6q_core::model::{Profile, TargetModel};
use g6q_core::Json;

/// One aspect of the design a stock machine cannot reproduce.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Delta {
    /// What differs, e.g. `"memory-map"`.
    pub aspect: String,
    /// What the design specifies.
    pub design: String,
    /// What the stock machine provides instead.
    pub stock: String,
}

impl Delta {
    /// Render as JSON.
    pub fn to_json(&self) -> Json {
        Json::obj([
            ("aspect", Json::str(&self.aspect)),
            ("design", Json::str(&self.design)),
            ("stock", Json::str(&self.stock)),
        ])
    }
}

/// What a stock generic RISC-V machine provides, for comparison purposes.
///
/// Deliberately a *parameter* rather than a constant table: the reference machine changes
/// between QEMU releases, and hard-coding it here would reintroduce exactly the
/// second-source-of-truth problem the package exists to avoid.
#[derive(Debug, Clone)]
pub struct StockMachine {
    /// Machine name passed to `-M`.
    pub name: String,
    /// Peripheral ids the stock machine provides.
    pub peripherals: Vec<String>,
    /// External interrupt sources.
    pub intc_sources: u32,
    /// External interrupt contexts.
    pub intc_targets: u32,
}

/// Compare a model against a stock machine.
///
/// Every peripheral the design has and the stock machine lacks is a delta, as is any
/// interrupt-geometry difference. Peripherals the stock machine has and the design does
/// not are also reported: an emulated device the hardware does not have is just as
/// capable of producing a misleading green.
pub fn capability_delta(model: &TargetModel, stock: &StockMachine) -> Vec<Delta> {
    let mut out = Vec::new();

    for p in &model.soc.peripherals {
        if !stock.peripherals.iter().any(|s| s == &p.id) {
            out.push(Delta {
                aspect: format!("peripheral:{}", p.id),
                design: format!("{} at {:#x} length {:#x}", p.id, p.base, p.len),
                stock: format!("absent from machine '{}'", stock.name),
            });
        }
    }
    for s in &stock.peripherals {
        if !model.soc.peripherals.iter().any(|p| &p.id == s) {
            out.push(Delta {
                aspect: format!("peripheral:{s}"),
                design: "not present in the design".to_string(),
                stock: format!("provided by machine '{}'", stock.name),
            });
        }
    }
    if model.soc.intc_sources != stock.intc_sources {
        out.push(Delta {
            aspect: "interrupt-sources".to_string(),
            design: model.soc.intc_sources.to_string(),
            stock: stock.intc_sources.to_string(),
        });
    }
    if model.soc.intc_targets != stock.intc_targets {
        out.push(Delta {
            aspect: "interrupt-targets".to_string(),
            design: model.soc.intc_targets.to_string(),
            stock: stock.intc_targets.to_string(),
        });
    }
    out
}

/// A B0 emission: the argv to run, and what that run does not cover.
#[derive(Debug, Clone)]
pub struct Emission {
    /// Command-line arguments, excluding the binary itself.
    pub argv: Vec<String>,
    /// Everything the stock machine cannot express.
    pub delta: Vec<Delta>,
    /// The machine profile this emission belongs to.
    pub profile: Profile,
}

impl Emission {
    /// Render as JSON, always carrying the profile stamp and the evidence disclaimer.
    pub fn to_json(&self) -> Json {
        Json::obj([
            ("argv", Json::arr(self.argv.iter().map(Json::str))),
            ("delta", Json::arr(self.delta.iter().map(Delta::to_json))),
            ("profile", Json::str(self.profile.as_str())),
            ("evidence", Json::Bool(false)),
        ])
    }

    /// Whether this emission has any unreported approximation.
    pub fn is_exact(&self) -> bool {
        self.delta.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use g6q_core::model::{Peripheral, Soc};

    fn periph(id: &str, base: u64, len: u64) -> Peripheral {
        Peripheral {
            id: id.into(),
            base,
            len,
            ..Peripheral::default()
        }
    }

    fn model_with(peripherals: Vec<Peripheral>, sources: u32, targets: u32) -> TargetModel {
        let mut m = TargetModel::new("t");
        m.soc = Soc {
            peripherals,
            intc_sources: sources,
            intc_targets: targets,
            ..Soc::default()
        };
        m
    }

    fn stock() -> StockMachine {
        StockMachine {
            name: "virt".into(),
            peripherals: vec!["clint".into(), "plic".into(), "uart".into()],
            intc_sources: 96,
            intc_targets: 2,
        }
    }

    #[test]
    fn a_design_only_peripheral_is_reported() {
        let m = model_with(
            vec![
                periph("clint", 0x200_0000, 0xc_0000),
                periph("accel", 0x4000_0000, 0x1000),
            ],
            96,
            2,
        );
        let d = capability_delta(&m, &stock());
        assert!(d.iter().any(|x| x.aspect == "peripheral:accel"), "{d:?}");
    }

    #[test]
    fn a_stock_only_peripheral_is_also_reported() {
        // An emulated device the hardware lacks can produce a misleading green just as
        // easily as a missing one.
        let m = model_with(vec![periph("clint", 0x200_0000, 0xc_0000)], 96, 2);
        let d = capability_delta(&m, &stock());
        assert!(d.iter().any(|x| x.aspect == "peripheral:uart"), "{d:?}");
    }

    #[test]
    fn interrupt_geometry_differences_are_reported() {
        let m = model_with(vec![], 30, 16);
        let d = capability_delta(&m, &stock());
        assert!(d.iter().any(|x| x.aspect == "interrupt-sources"));
        assert!(d.iter().any(|x| x.aspect == "interrupt-targets"));
    }

    #[test]
    fn an_identical_machine_has_no_delta() {
        let s = stock();
        let m = model_with(
            s.peripherals
                .iter()
                .map(|id| periph(id, 0, 0x1000))
                .collect(),
            s.intc_sources,
            s.intc_targets,
        );
        assert!(capability_delta(&m, &s).is_empty());
    }

    #[test]
    fn emission_json_stamps_profile_and_denies_evidence() {
        let e = Emission {
            argv: vec!["-M".into(), "virt".into()],
            delta: vec![],
            profile: Profile::Soc,
        };
        let text = e.to_json().to_pretty();
        assert!(text.contains("\"profile\": \"g6lc-soc\""), "{text}");
        assert!(text.contains("\"evidence\": false"), "{text}");
        assert!(e.is_exact());
    }
}
