// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! B1 build-wiring emitter.
//!
//! Emits small text fragments that wire the generated machine and CPU into QEMU's
//! meson/Kconfig build. The fragments are **text only** and become part of QEMU, a
//! separate GPL work.

use g6q_core::model::TargetModel;

use crate::machine::machine_name;
use crate::{Emission, EmittedFile};

/// Emit build-wiring fragments for the generated machine and CPU.
pub fn emit_build_wiring(model: &TargetModel, version: &str, digest: &str) -> Emission {
    let name = machine_name(&model.target_id);
    let upper = name.to_uppercase();
    let mut emission = Emission::new();

    // A single human- and machine-readable integration guide.
    let mut body = String::new();
    body.push_str("# Generated build-wiring fragments for the g6lc machine and CPU.\n");
    body.push_str("# Copy each section into the QEMU file it names.\n\n");

    body.push_str("# 1. Append to hw/riscv/Kconfig\n");
    body.push_str(&format!("config G6LC_{upper}\n"));
    body.push_str("    bool\n");
    body.push_str("    default y\n");
    body.push_str("    depends on RISCV32 || RISCV64\n");
    body.push_str("    select RISCV_ACLINT\n");
    body.push_str("    select SIFIVE_PLIC\n");
    body.push_str("    select SERIAL_MM\n\n");

    body.push_str("# 2. Append to configs/targets/riscv64-softmmu.mak (or the matching configs/targets file)\n");
    body.push_str(&format!("CONFIG_G6LC_{upper}=y\n\n"));

    body.push_str("# 3. Append to hw/riscv/meson.build\n");
    body.push_str(&format!(
        "riscv_ss.add(when: 'CONFIG_G6LC_{upper}', if_true: files(\n"
    ));
    body.push_str(&format!("        'g6lc-{name}-machine.c',\n"));
    body.push_str(&format!("        'g6lc-{name}-dtb.c',\n"));
    body.push_str("    ))\n\n");

    body.push_str("# 4. Append to target/riscv/meson.build\n");
    body.push_str(&format!(
        "riscv_ss.add(when: 'CONFIG_G6LC_{upper}', if_true: files('cpu_g6lc_{name}.c'))\n\n"
    ));

    body.push_str("# 5. Plugin build wiring\n");
    body.push_str("#    contrib/plugins/g6lc-");
    body.push_str(&name);
    body.push_str(".c is copied by the installer;\n");
    body.push_str("#    the installer adds 'g6lc-");
    body.push_str(&name);
    body.push_str("' to the contrib_plugins list in\n");
    body.push_str("#    contrib/plugins/meson.build (before the foreach loop).\n");
    body.push_str("#    Build with: ninja -C build contrib-plugins.\n");

    emission.push(EmittedFile::new(
        format!("build/build-wiring-{name}.txt"),
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
    fn build_wiring_has_gpl_header_and_config_references() {
        let m = TargetModel::new("g6lc64_test");
        let e = emit_build_wiring(&m, "0.1.0", "sha256:abc");
        assert_eq!(e.files.len(), 1);
        let f = &e.files[0];
        assert!(f.header_is_valid());
        assert!(f.contents.contains("CONFIG_G6LC_G6LC64_TEST"));
        assert!(f.contents.contains("g6lc-g6lc64_test-machine.c"));
        assert!(f.contents.contains("g6lc-g6lc64_test-dtb.c"));
        assert!(f.contents.contains("cpu_g6lc_g6lc64_test.c"));
        assert!(f.contents.contains("configs/targets/riscv64-softmmu.mak"));
        assert!(f.contents.contains("contrib/plugins/g6lc-g6lc64_test.c"));
        assert!(f.contents.contains("'g6lc-g6lc64_test'"));
    }
}
