// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! B1 QEMU CPU emitter.
//!
//! Emits a per-target `RISCVCPU` subclass with the model's extension gating.
//! The file is **text only** and becomes part of QEMU, a separate GPL work.

use g6q_core::model::TargetModel;

use crate::machine::machine_name;
use crate::{Emission, EmittedFile};

/// Tokens that map to a MISA extension bit in QEMU's `target/riscv/cpu.h`.
fn misa_macro_for(token: &str) -> Option<&'static str> {
    match token {
        "i" => Some("RVI"),
        "e" => Some("RVE"),
        "m" => Some("RVM"),
        "a" => Some("RVA"),
        "f" => Some("RVF"),
        "d" => Some("RVD"),
        "c" => Some("RVC"),
        "s" => Some("RVS"),
        "u" => Some("RVU"),
        "h" => Some("RVH"),
        "v" => Some("RVV"),
        "b" => Some("RVB"),
        "g" => Some("RVG"),
        _ => None,
    }
}

/// Tokens that map to a `RISCVCPUConfig.ext_*` field.
fn is_cpu_cfg_token(token: &str) -> bool {
    matches!(
        token,
        "zba"
            | "zbb"
            | "zbc"
            | "zbs"
            | "zca"
            | "zcb"
            | "zcd"
            | "zcf"
            | "zfa"
            | "zicbom"
            | "zicboz"
            | "zicbop"
            | "zicond"
            | "zicntr"
            | "zicsr"
            | "zifencei"
            | "zihintpause"
            | "sstc"
            | "svnapot"
            | "svpbmt"
            | "zawrs"
            | "zacas"
            | "zkn"
            | "zks"
            | "zkt"
            | "zvkb"
            | "zvkn"
            | "zvksc"
    )
}

/// Emit the CPU C file for a model.
pub fn emit_cpu(model: &TargetModel, version: &str, digest: &str) -> Emission {
    let name = machine_name(&model.target_id);
    let upper = name.to_uppercase();
    let mut emission = Emission::new();

    let mut body = String::new();
    body.push_str("#include \"qemu/osdep.h\"\n");
    body.push_str("#include \"target/riscv/cpu.h\"\n");
    body.push_str("#include \"target/riscv/cpu-qom.h\"\n");
    body.push_str("#include \"qom/object.h\"\n\n");

    // CPU type macro.
    body.push_str(&format!(
        "#define TYPE_G6LC_{upper}_CPU RISCV_CPU_TYPE_NAME(\"g6lc-{name}\")\n\n"
    ));

    // MISA MXL from xlen.
    let mxl = if model.isa.xlen == 32 {
        "MXL_RV32"
    } else {
        "MXL_RV64"
    };

    let mmu_enabled = model.isa.mmu_mode.is_some();
    let satp_mask = match model.isa.mmu_mode.as_deref() {
        Some("sv32") => "(1U << VM_1_10_MBARE) | (1U << VM_1_10_SV32)",
        Some("sv39") => "(1U << VM_1_10_MBARE) | (1U << VM_1_10_SV39)",
        Some("sv48") => "(1U << VM_1_10_MBARE) | (1U << VM_1_10_SV39) | (1U << VM_1_10_SV48)",
        Some("sv57") => {
            "(1U << VM_1_10_MBARE) | (1U << VM_1_10_SV39) |
                         (1U << VM_1_10_SV48) | (1U << VM_1_10_SV57)"
        }
        _ => "(1U << VM_1_10_MBARE)",
    };

    // Build MISA mask and per-instance cfg assignments from the ISA view.
    let mut misa_parts: Vec<&str> = Vec::new();
    let mut cfg_lines: Vec<String> = Vec::new();
    let mut base_isa = false;
    let mut general_isa = false;

    for (token, verdict) in &model.isa.extensions {
        if verdict != "live" {
            continue;
        }
        if let Some(bit) = misa_macro_for(token) {
            misa_parts.push(bit);
            if token == "i" || token == "g" {
                base_isa = true;
            }
            if token == "g" {
                general_isa = true;
            }
        } else if is_cpu_cfg_token(token) {
            cfg_lines.push(format!("    cpu->cfg.ext_{token} = true;"));
        }
    }

    // PMU: QEMU defaults zihpm to true and pmu_mask to 16 counters. We set
    // both explicitly so the generated CPU matches the design's counter unit.
    let pmu_live = model
        .isa
        .extensions
        .iter()
        .any(|(t, v)| t == "zihpm" && v == "live");
    let sscofpmf_live = model
        .isa
        .extensions
        .iter()
        .any(|(t, v)| t == "sscofpmf" && v == "live");
    if pmu_live {
        cfg_lines.push("    cpu->cfg.ext_zihpm = true;".into());
        cfg_lines.push(format!(
            "    cpu->cfg.pmu_mask = {:#x};",
            model.pmu.counter_mask()
        ));
        cfg_lines.push(if sscofpmf_live {
            "    cpu->cfg.ext_sscofpmf = true;".into()
        } else {
            "    cpu->cfg.ext_sscofpmf = false;".into()
        });
    } else {
        cfg_lines.push("    cpu->cfg.ext_zihpm = false;".into());
        cfg_lines.push("    cpu->cfg.pmu_mask = 0x0;".into());
        cfg_lines.push("    cpu->cfg.ext_sscofpmf = false;".into());
    }

    // Zicsr and Zifencei are required for the base I/G integer ISA in QEMU.
    if base_isa || general_isa {
        cfg_lines.push("    cpu->cfg.ext_zicsr = true;".into());
        cfg_lines.push("    cpu->cfg.ext_zifencei = true;".into());
    }

    // QEMU's MISA validation requires U whenever S is present.
    let has_s = misa_parts.iter().any(|&p| p == "RVS");
    let has_u = misa_parts.iter().any(|&p| p == "RVU");
    if has_s && !has_u {
        misa_parts.push("RVU");
    }

    // Deduplicate while preserving insertion order.
    let mut seen: std::collections::HashSet<&str> = std::collections::HashSet::new();
    let mut unique_cfg: Vec<String> = Vec::new();
    for line in &cfg_lines {
        let trimmed = line.trim();
        if seen.insert(trimmed) {
            unique_cfg.push(line.clone());
        }
    }

    let misa_mask = if misa_parts.is_empty() {
        "0".to_string()
    } else {
        misa_parts.join(" | ")
    };

    body.push_str(&format!(
        "static void g6lc_{name}_cpu_class_init(ObjectClass *oc, void *data)\n{{\n"
    ));
    body.push_str("    RISCVCPUClass *rcc = RISCV_CPU_CLASS(oc);\n\n");
    body.push_str(&format!("    rcc->misa_mxl_max = {mxl};\n"));
    body.push_str("}\n\n");

    body.push_str(&format!(
        "static void g6lc_{name}_cpu_instance_init(Object *obj)\n{{\n"
    ));
    body.push_str("    RISCVCPU *cpu = RISCV_CPU(obj);\n");
    body.push_str("    CPURISCVState *env = &cpu->env;\n\n");
    body.push_str(&format!("    riscv_cpu_set_misa_ext(env, {misa_mask});\n"));
    body.push_str("    env->priv_ver = PRIV_VERSION_1_12_0;\n");
    if mmu_enabled {
        body.push_str("    cpu->cfg.mmu = true;\n");
        body.push_str("    cpu->cfg.pmp = true;\n");
    }
    body.push_str(&format!(
        "    cpu->cfg.satp_mode.supported = {satp_mask};\n"
    ));
    for line in &unique_cfg {
        body.push_str(line);
        body.push('\n');
    }
    body.push_str("}\n\n");

    body.push_str(&format!(
        "static const TypeInfo g6lc_{name}_cpu_type_info = {{\n"
    ));
    body.push_str(&format!("    .name = TYPE_G6LC_{upper}_CPU,\n"));
    body.push_str("    .parent = TYPE_RISCV_VENDOR_CPU,\n");
    body.push_str("    .instance_init = g6lc_");
    body.push_str(&name);
    body.push_str("_cpu_instance_init,\n");
    body.push_str("    .class_init = g6lc_");
    body.push_str(&name);
    body.push_str("_cpu_class_init,\n");
    body.push_str("};\n\n");

    body.push_str(&format!(
        "static void g6lc_{name}_cpu_register_types(void)\n{{\n"
    ));
    body.push_str("    type_register_static(&g6lc_");
    body.push_str(&name);
    body.push_str("_cpu_type_info);\n}\n\n");

    body.push_str("type_init(g6lc_");
    body.push_str(&name);
    body.push_str("_cpu_register_types)\n");

    emission.push(EmittedFile::new(
        format!("target/riscv/cpu_g6lc_{name}.c"),
        version,
        digest,
        &body,
    ));

    emission
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn emitted_cpu_has_gpl_header_and_type() {
        let mut m = TargetModel::new("g6lc64_test");
        m.isa.xlen = 64;
        m.isa.extensions = vec![
            ("i".into(), "live".into()),
            ("m".into(), "live".into()),
            ("zbb".into(), "live".into()),
            ("zba".into(), "absent".into()),
        ];

        let e = emit_cpu(&m, "0.1.0", "sha256:abc");
        assert_eq!(e.files.len(), 1);
        let f = &e.files[0];
        assert!(f.header_is_valid());
        assert!(f.contents.contains("TYPE_G6LC_G6LC64_TEST_CPU"));
        assert!(f.contents.contains("rcc->misa_mxl_max = MXL_RV64"));
        assert!(f
            .contents
            .contains("riscv_cpu_set_misa_ext(env, RVI | RVM)"));
        assert!(f.contents.contains("cpu->cfg.ext_zbb = true"));
        assert!(f.contents.contains("cpu->cfg.ext_zicsr = true"));
        assert!(!f.contents.contains("cpu->cfg.ext_zba"));
        assert!(f.contents.contains("cpu->cfg.ext_zihpm = false"));
        assert!(f.contents.contains("cpu->cfg.pmu_mask = 0x0"));
        assert!(f.contents.contains("cpu->cfg.ext_sscofpmf = false"));
    }

    #[test]
    fn emitted_cpu_sets_pmu_mask_when_zihpm_live() {
        let mut m = TargetModel::new("g6lc64_pmu");
        m.isa.xlen = 64;
        m.isa.extensions = vec![
            ("i".into(), "live".into()),
            ("zihpm".into(), "live".into()),
            ("sscofpmf".into(), "live".into()),
        ];
        m.pmu.counter_count = 6;

        let e = emit_cpu(&m, "0.1.0", "sha256:abc");
        let f = &e.files[0];
        assert!(f.contents.contains("cpu->cfg.ext_zihpm = true"));
        assert!(f.contents.contains("cpu->cfg.pmu_mask = 0x1f8"));
        assert!(f.contents.contains("cpu->cfg.ext_sscofpmf = true"));
    }

    #[test]
    fn emitted_cpu_uses_rv32_when_requested() {
        let mut m = TargetModel::new("t");
        m.isa.xlen = 32;
        let e = emit_cpu(&m, "0.1.0", "sha256:abc");
        assert!(e.files[0].contents.contains("rcc->misa_mxl_max = MXL_RV32"));
    }
}
