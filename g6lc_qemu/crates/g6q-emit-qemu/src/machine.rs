// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! B1 QEMU machine emitter.
//!
//! Emits a C machine file for the pinned QEMU revision. The file is **text only**: it
//! becomes part of QEMU, a separate GPL work, and carries the GPL-2.0-or-later header.

use g6q_core::model::TargetModel;

use crate::{Emission, EmittedFile};

/// Render a 64-bit constant as a `0x`-prefixed `ULL` suffix.
fn hex_ull(v: u64) -> String {
    format!("{v:#x}ULL")
}

/// Sanitize the target id into a C identifier.
/// Sanitise a target id into a valid C identifier token.
pub fn machine_name(target_id: &str) -> String {
    target_id
        .chars()
        .map(|c| match c {
            'a'..='z' | 'A'..='Z' | '0'..='9' => c,
            _ => '_',
        })
        .collect()
}

/// Merge any virtio-mmio transports requested by the machine profile into the
/// design's own peripheral list. The base is the next 4 KiB-aligned page after
/// the end of DRAM and every design peripheral, and each transport occupies one
/// page. This is a machine-profile choice, not an RTL constant.
pub(crate) fn merged_peripherals(model: &TargetModel) -> Vec<g6q_core::model::Peripheral> {
    let mut all = model.soc.peripherals.clone();
    if model.soc.virtio_mmio != 0 {
        let mut max_end = model.soc.dram.map_or(0, |(b, l)| b + l);
        for p in &model.soc.peripherals {
            max_end = max_end.max(p.base + p.len);
        }
        let aligned = (max_end + 0xfff) & !0xfff;
        let base = if aligned == 0 { 0x1000_1000 } else { aligned };
        let max_irq = model
            .soc
            .peripherals
            .iter()
            .filter_map(|p| p.irq)
            .max()
            .unwrap_or(0);
        for i in 0..model.soc.virtio_mmio {
            all.push(g6q_core::model::Peripheral {
                id: format!("virtio{i}"),
                base: base + (i as u64) * 0x1000,
                len: 0x1000,
                model: Some("virtio-mmio".into()),
                irq: Some(max_irq + i + 1),
                ..g6q_core::model::Peripheral::default()
            });
        }
    }
    all
}

/// Emit the machine C file for a model.
pub fn emit_machine(model: &TargetModel, version: &str, digest: &str) -> Emission {
    let name = machine_name(&model.target_id);
    let upper = name.to_uppercase();
    let mut emission = Emission::new();

    let all_peripherals = merged_peripherals(model);

    // Decide whether the model constants are actually referenced, to avoid
    // -Werror=unused-const-variable warnings.
    let harts_total_used = !all_peripherals.is_empty()
        || (model.soc.intc_targets != 0 && model.soc.contexts_per_hart != 0);
    let intc_sources_used = !all_peripherals.is_empty();
    let has_clint = all_peripherals.iter().any(|p| {
        p.model
            .as_deref()
            .map(|m| m.contains("clint"))
            .unwrap_or(false)
    });
    let has_plic = all_peripherals.iter().any(|p| {
        p.model
            .as_deref()
            .map(|m| m.contains("plic") || m.contains("intc"))
            .unwrap_or(false)
    });

    let mut body = String::new();
    body.push_str("#include \"qemu/osdep.h\"\n");
    body.push_str("#include \"qemu/units.h\"\n");
    body.push_str("#include \"qemu/error-report.h\"\n");
    body.push_str("#include \"qapi/error.h\"\n");
    body.push_str("#include \"hw/boards.h\"\n");
    body.push_str("#include \"hw/qdev-core.h\"\n");
    body.push_str("#include \"hw/qdev-properties.h\"\n");
    body.push_str("#include \"hw/sysbus.h\"\n");
    body.push_str("#include \"hw/loader.h\"\n");
    body.push_str("#include \"hw/riscv/riscv_hart.h\"\n");
    body.push_str("#include \"hw/riscv/boot.h\"\n");
    body.push_str(&format!("#include \"hw/riscv/g6lc-{name}-dtb.h\"\n"));
    // Gated on the *device emitter's* condition, not merely on an island being present:
    // including a header that was not emitted makes the QEMU tree unbuildable.
    let ai_device = crate::ai_island::resolved(model).is_some();
    if ai_device {
        body.push_str(&format!("#include \"hw/riscv/g6lc-{name}-ai-island.h\"\n"));
    }
    body.push_str("#include \"target/riscv/cpu.h\"\n");
    body.push_str("#include \"target/riscv/cpu-qom.h\"\n");
    body.push_str("#include \"exec/memory.h\"\n");
    body.push_str("#include \"system/device_tree.h\"\n");
    body.push_str("#include <libfdt.h>\n");
    if !all_peripherals.is_empty() {
        body.push_str("#include \"system/system.h\"\n");
    }
    if has_clint {
        body.push_str("#include \"hw/intc/riscv_aclint.h\"\n");
    }
    if has_plic {
        body.push_str("#include \"hw/intc/sifive_plic.h\"\n");
    }
    body.push_str("#include \"qom/object.h\"\n");
    let has_spi = all_peripherals.iter().any(|p| {
        p.model
            .as_deref()
            .map(|m| {
                let m = m.to_lowercase();
                m.contains("xps-spi") || m.contains("axi-quad-spi")
            })
            .unwrap_or(false)
    });
    if has_spi {
        body.push_str("#include \"hw/irq.h\"\n");
        body.push_str("#include \"hw/ssi/ssi.h\"\n");
        body.push_str("#include \"system/blockdev.h\"\n");
    }
    body.push('\n');

    // Machine and CPU type macros.
    body.push_str(&format!(
        "#define TYPE_G6LC_{upper}_MACHINE MACHINE_TYPE_NAME(\"g6lc-{name}\")\n"
    ));
    body.push_str(&format!(
        "#define TYPE_G6LC_{upper}_CPU RISCV_CPU_TYPE_NAME(\"g6lc-{name}\")\n\n"
    ));

    // Memory map constants, derived from the model.
    if let Some((base, len)) = model.soc.dram {
        body.push_str(&format!(
            "static const uint64_t dram_base = {};\n",
            hex_ull(base)
        ));
        body.push_str(&format!(
            "static const uint64_t dram_size = {};\n",
            hex_ull(len)
        ));
    } else {
        body.push_str("static const uint64_t dram_base = 0x80000000ULL;\n");
        body.push_str("static const uint64_t dram_size = 0x40000000ULL;\n");
    }

    if harts_total_used {
        body.push_str(&format!(
            "static const uint32_t g6lc_harts_total = {};\n",
            model.soc.harts_total
        ));
    }
    body.push_str(&format!(
        "static const bool g6lc_is_32bit = {};\n",
        if model.isa.xlen == 32 {
            "true"
        } else {
            "false"
        }
    ));
    if model.soc.intc_targets != 0 {
        body.push_str(&format!(
            "static const uint32_t g6lc_intc_targets = {};\n",
            model.soc.intc_targets
        ));
    }
    if model.soc.contexts_per_hart != 0 {
        body.push_str(&format!(
            "static const uint32_t g6lc_contexts_per_hart = {};\n",
            model.soc.contexts_per_hart
        ));
    }
    let max_irq = all_peripherals
        .iter()
        .filter_map(|p| p.irq)
        .max()
        .unwrap_or(0);
    let g6lc_intc_sources = model.soc.intc_sources.max(max_irq + 1);
    if intc_sources_used && g6lc_intc_sources != 0 {
        body.push_str(&format!(
            "static const uint32_t g6lc_intc_sources = {};\n",
            g6lc_intc_sources
        ));
    }
    if has_clint {
        body.push_str(&format!(
            "static const uint32_t g6lc_timebase_freq = {};\n",
            model.isa.timebase_hz
        ));
    }
    body.push('\n');

    if !all_peripherals.is_empty() {
        body.push_str("/* Memory-map peripherals from the design's SoC package. */\n");
        body.push_str("static const struct {\n");
        body.push_str("    const char *id;\n");
        body.push_str("    uint64_t base;\n");
        body.push_str("    uint64_t len;\n");
        body.push_str("    const char *model;\n");
        body.push_str("    int64_t irq;\n");
        body.push_str("    uint8_t reg_shift;\n");
        body.push_str("    uint32_t clock_frequency;\n");
        body.push_str("} g6lc_peripherals[] = {\n");
        for p in &all_peripherals {
            let m = p.model.as_deref().unwrap_or("");
            let irq = p.irq.map(|i| i as i64).unwrap_or(-1);
            let reg_shift = p.reg_shift.unwrap_or(0);
            let clock = p.clock_frequency.unwrap_or(0);
            body.push_str(&format!(
                "    {{ \"{id}\", {base}, {len}, \"{model}\", {irq}, {reg_shift}, {clock} }},\n",
                id = p.id,
                base = hex_ull(p.base),
                len = hex_ull(p.len),
                model = m,
                irq = irq,
                reg_shift = reg_shift,
                clock = clock
            ));
        }
        body.push_str("};\n\n");
    }

    // Self-check: assert the memory map is sane and hart count fits the controller.
    body.push_str(&format!(
        "static void g6lc_{name}_machine_self_check(void)\n{{\n"
    ));
    body.push_str("    /* Memory window integrity. */\n");
    body.push_str("    g_assert(dram_base > 0);\n");
    body.push_str("    g_assert(dram_size > 0);\n");
    body.push_str("    g_assert((dram_base & 0xfff) == 0);\n");
    if !all_peripherals.is_empty() {
        body.push_str("    for (size_t i = 0; i < ARRAY_SIZE(g6lc_peripherals); ++i) {\n");
        body.push_str("        const uint64_t p_base = g6lc_peripherals[i].base;\n");
        body.push_str("        const uint64_t p_end = p_base + g6lc_peripherals[i].len;\n");
        body.push_str("        g_assert(p_base > 0 || g6lc_peripherals[i].len == 0);\n");
        body.push_str("        /* No overlap with DRAM. */\n");
        body.push_str("        g_assert(p_end <= dram_base || p_base >= dram_base + dram_size);\n");
        body.push_str("        /* No overlap with later peripherals. */\n");
        body.push_str("        for (size_t j = i + 1; j < ARRAY_SIZE(g6lc_peripherals); ++j) {\n");
        body.push_str("            const uint64_t q_base = g6lc_peripherals[j].base;\n");
        body.push_str("            const uint64_t q_end = q_base + g6lc_peripherals[j].len;\n");
        body.push_str("            g_assert(p_end <= q_base || q_end <= p_base);\n");
        body.push_str("        }\n");
        body.push_str("    }\n");
    }
    if model.soc.intc_targets != 0 && model.soc.contexts_per_hart != 0 {
        body.push_str("    /* Hart count fits the interrupt-controller geometry. */\n");
        body.push_str("    g_assert(g6lc_harts_total <=\n");
        body.push_str("             g6lc_intc_targets / g6lc_contexts_per_hart);\n");
    }
    body.push_str("}\n\n");

    body.push_str(&format!(
        "static void g6lc_{name}_machine_fdt_check(const void *fdt)\n{{\n"
    ));
    body.push_str("    int cpus_off = fdt_path_offset(fdt, \"/cpus\");\n");
    body.push_str("    g_assert(cpus_off >= 0);\n");
    body.push_str("    int count = 0;\n");
    body.push_str("    int node;\n");
    body.push_str("    fdt_for_each_subnode(node, fdt, cpus_off) {\n");
    body.push_str("        const char *n = fdt_get_name(fdt, node, NULL);\n");
    body.push_str("        if (n && strncmp(n, \"cpu@\", 4) == 0) {\n");
    body.push_str("            count++;\n");
    body.push_str("        }\n");
    body.push_str("    }\n");
    body.push_str("    g_assert(count == (int)g6lc_harts_total);\n");
    body.push_str("}\n\n");

    // Peripheral device creation, driven by the design's model field.
    if !all_peripherals.is_empty() {
        body.push_str("static const char *g6lc_qom_type_for_model(const char *model)\n{\n");
        body.push_str("    if (!model || !model[0])\n");
        body.push_str("        return NULL;\n");
        body.push_str("    if (strstr(model, \"virtio-mmio\"))\n");
        body.push_str("        return \"virtio-mmio\";\n");
        body.push_str("    if (strstr(model, \"ns16550\"))\n");
        body.push_str("        return \"serial-mm\";\n");
        body.push_str("    /* QEMU v10 splits the CLINT into ACLINT SWI + MTIMER; see below. */\n");
        body.push_str("    if (strstr(model, \"clint\"))\n");
        body.push_str("        return NULL;\n");
        body.push_str("    if (strstr(model, \"plic\") || strstr(model, \"intc\"))\n");
        body.push_str("        return \"riscv.sifive.plic\";\n");
        if ai_device {
            body.push_str(
                "    /* The generated AI-island device owns this window; see pass 2. */\n",
            );
            body.push_str("    if (strstr(model, \"ai-island\"))\n");
            body.push_str("        return NULL;\n");
        }
        body.push_str("    if (strstr(model, \"ai-island\") || strstr(model, \"ai-matrix\"))\n");
        body.push_str("        return \"unimplemented-device\";\n");
        body.push_str("    if (strstr(model, \"xps-spi\") || strstr(model, \"axi-quad-spi\"))\n");
        body.push_str("        return \"xlnx.xps-spi\";\n");
        body.push_str("    return NULL;\n");
        body.push_str("}\n\n");

        body.push_str(&format!(
            "static void g6lc_{name}_create_peripherals(MachineState *machine)\n{{\n"
        ));
        body.push_str("    DeviceState *plic_dev = NULL;\n\n");
        body.push_str(
            "    /* Pass 1: create controllers so downstream devices can wire to them. */\n",
        );
        body.push_str("    for (size_t i = 0; i < ARRAY_SIZE(g6lc_peripherals); ++i) {\n");
        body.push_str(
            "        const char *qom = g6lc_qom_type_for_model(g6lc_peripherals[i].model);\n",
        );
        body.push_str("        DeviceState *dev = NULL;\n");
        body.push_str("        if (!qom) {\n");
        body.push_str("            continue;\n");
        body.push_str("        }\n");
        body.push_str("        if (strcmp(qom, \"riscv.sifive.plic\") == 0) {\n");
        body.push_str("            g_autofree char *plic_hart_config =\n");
        body.push_str("                riscv_plic_hart_config_string(g6lc_harts_total);\n");
        body.push_str("            plic_dev = sifive_plic_create(\n");
        body.push_str("                g6lc_peripherals[i].base, plic_hart_config,\n");
        body.push_str("                g6lc_harts_total, 0,\n");
        body.push_str("                g6lc_intc_sources,\n");
        body.push_str("                0,\n");
        body.push_str("                0, 0x1000, 0x2000, 0x80,\n");
        body.push_str("                0x200000, 0x1000,\n");
        body.push_str("                g6lc_peripherals[i].len);\n");
        body.push_str("            continue;\n");
        body.push_str("        }\n");
        body.push_str("        if (!dev) {\n");
        body.push_str("            continue;\n");
        body.push_str("        }\n");
        body.push_str("        sysbus_realize_and_unref(SYS_BUS_DEVICE(dev), &error_fatal);\n");
        body.push_str(
            "        sysbus_mmio_map(SYS_BUS_DEVICE(dev), 0, g6lc_peripherals[i].base);\n",
        );
        body.push_str("    }\n\n");
        body.push_str("    /* Pass 2: create devices and connect their IRQs to the PLIC. */\n");
        body.push_str("    for (size_t i = 0; i < ARRAY_SIZE(g6lc_peripherals); ++i) {\n");
        body.push_str(
            "        const char *qom = g6lc_qom_type_for_model(g6lc_peripherals[i].model);\n",
        );
        body.push_str("        DeviceState *dev = NULL;\n");
        if ai_device {
            let ai = model.soc.ai_island.as_ref().unwrap();
            // The window *bases* are decided by the island's address decode, which the
            // reader cannot consume (Change set B4). Absence is passed through as a
            // "not decoded" flag rather than substituted with a plausible address: a wrong
            // base relocates the whole window while every field still looks correctly
            // placed relative to its neighbours.
            let (cap_decoded, cap_base) = match ai.config.cap_base {
                Some(b) => ("true", b),
                None => ("false", 0),
            };
            let (desc_decoded, desc_base) = match ai.config.desc_base {
                Some(b) => ("true", b),
                None => ("false", 0),
            };
            body.push_str("        if (strstr(g6lc_peripherals[i].model, \"ai-island\")) {\n");
            body.push_str("            g6lc_ai_island_create(g6lc_peripherals[i].base,\n");
            body.push_str("                                  g6lc_peripherals[i].len,\n");
            body.push_str(&format!(
                "                                  {cap_decoded}, {cap_base}ULL,\n\
                 \x20                                 {desc_decoded}, {desc_base}ULL);\n"
            ));
            body.push_str("            continue;\n");
            body.push_str("        }\n");
        }
        body.push_str("        if (!qom || strcmp(qom, \"riscv.sifive.plic\") == 0) {\n");
        body.push_str("            continue;\n");
        body.push_str("        }\n");
        body.push_str("        if (strcmp(qom, \"unimplemented-device\") == 0) {\n");
        body.push_str("            dev = qdev_new(qom);\n");
        body.push_str("            qdev_prop_set_uint64(dev, \"size\",\n");
        body.push_str("                                g6lc_peripherals[i].len);\n");
        body.push_str("            qdev_prop_set_string(dev, \"name\",\n");
        body.push_str("                                  g6lc_peripherals[i].model);\n");
        body.push_str("        }\n");
        body.push_str("        if (strcmp(qom, \"virtio-mmio\") == 0) {\n");
        body.push_str("            dev = qdev_new(\"virtio-mmio\");\n");
        body.push_str("        }\n");
        body.push_str("        if (strcmp(qom, \"serial-mm\") == 0) {\n");
        body.push_str("            dev = qdev_new(qom);\n");
        body.push_str("            qdev_prop_set_chr(dev, \"chardev\", serial_hd(0));\n");
        body.push_str("            if (g6lc_peripherals[i].reg_shift) {\n");
        body.push_str("                qdev_prop_set_uint8(dev, \"regshift\",\n");
        body.push_str("                                    g6lc_peripherals[i].reg_shift);\n");
        body.push_str("            }\n");
        body.push_str("            if (g6lc_peripherals[i].clock_frequency) {\n");
        body.push_str("                qdev_prop_set_uint32(dev, \"baudbase\",\n");
        body.push_str(
            "                                     g6lc_peripherals[i].clock_frequency / 16);\n",
        );
        body.push_str("            }\n");
        body.push_str("        }\n");
        body.push_str("        if (strcmp(qom, \"xlnx.xps-spi\") == 0) {\n");
        body.push_str("            SSIBus *spi;\n");
        body.push_str("            DeviceState *flash;\n");
        body.push_str("            DriveInfo *dinfo;\n");
        body.push_str("            qemu_irq cs_line;\n");
        body.push_str("            dev = qdev_new(\"xlnx.xps-spi\");\n");
        body.push_str("            qdev_prop_set_string(dev, \"endianness\", \"little\");\n");
        body.push_str("            qdev_prop_set_uint8(dev, \"num-ss-bits\", 1);\n");
        body.push_str("            sysbus_realize_and_unref(SYS_BUS_DEVICE(dev), &error_fatal);\n");
        body.push_str(
            "            sysbus_mmio_map(SYS_BUS_DEVICE(dev), 0, g6lc_peripherals[i].base);\n",
        );
        body.push_str("            if (g6lc_peripherals[i].irq >= 0 && plic_dev) {\n");
        body.push_str("                sysbus_connect_irq(SYS_BUS_DEVICE(dev), 0,\n");
        body.push_str("                    qdev_get_gpio_in(plic_dev,\n");
        body.push_str("                                     g6lc_peripherals[i].irq));\n");
        body.push_str("            }\n");
        body.push_str("            spi = (SSIBus *)qdev_get_child_bus(dev, \"spi\");\n");
        body.push_str("            flash = qdev_new(\"n25q256a\");\n");
        body.push_str("            dinfo = drive_get(IF_MTD, 0, 0);\n");
        body.push_str("            if (dinfo) {\n");
        body.push_str("                qdev_prop_set_drive_err(flash, \"drive\",\n");
        body.push_str("                                        blk_by_legacy_dinfo(dinfo),\n");
        body.push_str("                                        &error_fatal);\n");
        body.push_str("            }\n");
        body.push_str("            qdev_realize_and_unref(flash, BUS(spi), &error_fatal);\n");
        body.push_str("            cs_line = qdev_get_gpio_in_named(flash, SSI_GPIO_CS, 0);\n");
        body.push_str("            sysbus_connect_irq(SYS_BUS_DEVICE(dev), 1, cs_line);\n");
        body.push_str("            continue;\n");
        body.push_str("        }\n");
        body.push_str("        if (!dev) {\n");
        body.push_str("            continue;\n");
        body.push_str("        }\n");
        body.push_str("        sysbus_realize_and_unref(SYS_BUS_DEVICE(dev), &error_fatal);\n");
        body.push_str(
            "        sysbus_mmio_map(SYS_BUS_DEVICE(dev), 0, g6lc_peripherals[i].base);\n",
        );
        body.push_str("        if (g6lc_peripherals[i].irq >= 0 && plic_dev &&\n");
        body.push_str("            strcmp(qom, \"unimplemented-device\") != 0) {\n");
        body.push_str("            sysbus_connect_irq(SYS_BUS_DEVICE(dev), 0,\n");
        body.push_str("                             qdev_get_gpio_in(plic_dev,\n");
        body.push_str("                                              g6lc_peripherals[i].irq));\n");
        body.push_str("        }\n");
        body.push_str("    }\n\n");
        body.push_str("    /* QEMU v10 splits the CLINT into ACLINT MSWI and MTIMER. */\n");
        body.push_str("    for (size_t i = 0; i < ARRAY_SIZE(g6lc_peripherals); ++i) {\n");
        body.push_str("        if (!g6lc_peripherals[i].model ||\n");
        body.push_str("            !strstr(g6lc_peripherals[i].model, \"clint\")) {\n");
        body.push_str("            continue;\n");
        body.push_str("        }\n");
        body.push_str("        riscv_aclint_swi_create(g6lc_peripherals[i].base, 0,\n");
        body.push_str("                                g6lc_harts_total, false);\n");
        body.push_str("        riscv_aclint_mtimer_create(\n");
        body.push_str("            g6lc_peripherals[i].base + RISCV_ACLINT_SWI_SIZE,\n");
        body.push_str("            g6lc_peripherals[i].len > RISCV_ACLINT_SWI_SIZE\n");
        body.push_str("                ? g6lc_peripherals[i].len - RISCV_ACLINT_SWI_SIZE\n");
        body.push_str("                : RISCV_ACLINT_DEFAULT_MTIMER_SIZE,\n");
        body.push_str("            0, g6lc_harts_total,\n");
        body.push_str("            RISCV_ACLINT_DEFAULT_MTIMECMP,\n");
        body.push_str("            RISCV_ACLINT_DEFAULT_MTIME,\n");
        body.push_str("            g6lc_timebase_freq, true);\n");
        body.push_str("    }\n");
        body.push_str("}\n\n");
    }

    // Machine state and type registration.
    body.push_str(&format!(
        "typedef struct {upper}MachineState {upper}MachineState;\n"
    ));
    body.push_str(&format!(
        "DECLARE_INSTANCE_CHECKER({upper}MachineState, {upper}_MACHINE,\n"
    ));
    body.push_str(&format!(
        "                         TYPE_G6LC_{upper}_MACHINE)\n\n"
    ));
    body.push_str(&format!(
        "struct {upper}MachineState {{
"
    ));
    body.push_str("    MachineState parent;\n");
    body.push_str("    RISCVHartArrayState harts;\n");
    body.push_str("};\n\n");

    body.push_str(&format!(
        "static void g6lc_{name}_machine_init(MachineState *machine)\n{{\n"
    ));
    body.push_str("    ");
    body.push_str(&upper);
    body.push_str("MachineState *s = ");
    body.push_str(&upper);
    body.push_str("_MACHINE(machine);\n");
    body.push_str("    g6lc_");
    body.push_str(&name);
    body.push_str("_machine_self_check();\n");
    body.push_str("    MemoryRegion *system_memory = get_system_memory();\n\n");
    body.push_str("    /* Map the main DRAM region. */\n");
    body.push_str("    MemoryRegion *dram = g_new(MemoryRegion, 1);\n");
    body.push_str("    memory_region_init_ram(dram, NULL, \"g6lc.dram\",\n");
    body.push_str("                         dram_size, &error_fatal);\n");
    body.push_str("    memory_region_add_subregion(system_memory, dram_base, dram);\n\n");

    let has_mrom = model.soc.bootrom.is_some();
    let (mrom_base, mrom_size) = if let Some((b, s)) = model.soc.bootrom {
        (b, s)
    } else {
        (0x1000, 0x1000)
    };
    /* Map the MROM region. When the SoC does not provide one, a minimal
     * reset-vector MROM is synthesized at the RISC-V default reset vector. */
    body.push_str("    MemoryRegion *mrom = g_new(MemoryRegion, 1);\n");
    body.push_str("    memory_region_init_rom(mrom, NULL, \"g6lc.mrom\",\n");
    body.push_str(&format!(
        "                         {}, &error_fatal);\n",
        hex_ull(mrom_size)
    ));
    body.push_str(&format!(
        "    memory_region_add_subregion(system_memory, {}, mrom);\n\n",
        hex_ull(mrom_base)
    ));

    body.push_str("    /* Prepare boot information for the RISC-V loader helpers. */\n");
    body.push_str("    RISCVBootInfo info = {0};\n");
    body.push_str("    info.is_32bit = g6lc_is_32bit;\n\n");

    body.push_str("    /* Load the firmware (OpenSBI by default, unless -bios none). */\n");
    body.push_str("    hwaddr firmware_load_addr = dram_base;\n");
    body.push_str("    target_ulong firmware_end_addr = dram_base;\n");
    body.push_str("    target_ulong start_addr = dram_base;\n\n");
    body.push_str("    if (machine->firmware && strcmp(machine->firmware, \"none\") != 0) {\n");
    if has_mrom {
        let (mrom_base, _) = model.soc.bootrom.unwrap();
        body.push_str(&format!(
            "        firmware_load_addr = {};\n",
            hex_ull(mrom_base)
        ));
    } else {
        body.push_str("        firmware_load_addr = dram_base;\n");
    }
    body.push_str("        firmware_end_addr =\n");
    body.push_str("            riscv_find_and_load_firmware(machine,\n");
    body.push_str("                g6lc_is_32bit ? RISCV32_BIOS_BIN : RISCV64_BIOS_BIN,\n");
    body.push_str("                &firmware_load_addr, NULL);\n");
    body.push_str("        start_addr = (target_ulong)firmware_load_addr;\n");
    if !has_mrom {
        body.push_str("    } else {\n");
        body.push_str(
            "        /* No firmware requested; reset vector still jumps to the MROM. */\n",
        );
    }
    body.push_str("    }\n\n");

    body.push_str("    /* Resolve the device tree before -kernel so riscv_load_initrd can\n");
    body.push_str("     * write linux,initrd-* (QEMU virt does the same). */\n");
    body.push_str("    if (machine->dtb) {\n");
    body.push_str("        machine->fdt = load_device_tree(machine->dtb, NULL);\n");
    body.push_str("        if (!machine->fdt) {\n");
    body.push_str("            error_report(\"load_device_tree() failed\");\n");
    body.push_str("            exit(1);\n");
    body.push_str("        }\n");
    body.push_str("    } else if (!machine->fdt) {\n");
    body.push_str("        /* Packed blob has no slack for linux,initrd-* / bootargs. */\n");
    body.push_str(&format!("        const void *blob = g6lc_{name}_dtb;\n"));
    body.push_str(&format!(
        "        int blob_size = (int)g6lc_{name}_dtb_size;\n"
    ));
    body.push_str("        int fdt_size = blob_size * 2;\n");
    body.push_str("        if (fdt_size < blob_size + 0x1000) {\n");
    body.push_str("            fdt_size = blob_size + 0x1000;\n");
    body.push_str("        }\n");
    body.push_str("        machine->fdt = g_malloc0(fdt_size);\n");
    body.push_str("        if (fdt_open_into(blob, machine->fdt, fdt_size)) {\n");
    body.push_str("            error_report(\"fdt_open_into failed\");\n");
    body.push_str("            exit(1);\n");
    body.push_str("        }\n");
    body.push_str("    }\n\n");

    body.push_str("    /* Load -kernel at DRAM+2MiB (QEMU virt / U-Boot TEXT_BASE). */\n");
    body.push_str("    if (machine->kernel_filename) {\n");
    body.push_str("        target_ulong kernel_start_addr = dram_base + 0x200000ULL;\n");
    body.push_str("        if (kernel_start_addr < firmware_end_addr) {\n");
    body.push_str("            kernel_start_addr = firmware_end_addr;\n");
    body.push_str("        }\n");
    body.push_str("        riscv_load_kernel(machine, &info, kernel_start_addr, true, NULL);\n");
    body.push_str("        /* Reset enters firmware when -bios is set. S-mode payloads\n");
    body.push_str("         * (U-Boot qemu-riscv64_smode) cannot run from M-mode reset. */\n");
    body.push_str(
        "        if (!machine->firmware || strcmp(machine->firmware, \"none\") == 0) {\n",
    );
    body.push_str("            if (info.image_low_addr) {\n");
    body.push_str("                start_addr = info.image_low_addr;\n");
    body.push_str("            }\n");
    body.push_str("        }\n");
    body.push_str("    }\n\n");

    body.push_str("    /* OpenSBI's sanitize_domain() needs a next address outside firmware. */\n");
    body.push_str("    if (!info.image_low_addr) {\n");
    body.push_str("        info.image_low_addr = dram_base + 0x200000ULL;\n");
    body.push_str("    }\n\n");

    body.push_str("    /* Place and load the FDT near the end of RAM. */\n");
    body.push_str("    uint64_t fdt_addr = riscv_compute_fdt_addr(\n");
    body.push_str("        dram_base, dram_size, machine, &info);\n");
    body.push_str("    riscv_load_fdt(fdt_addr, machine->fdt);\n\n");
    body.push_str("    g6lc_");
    body.push_str(&name);
    body.push_str("_machine_fdt_check(machine->fdt);\n\n");

    body.push_str("    /* Realize the model's hart array. */\n");
    body.push_str("    object_initialize_child(OBJECT(machine), \"harts\",\n");
    body.push_str("                          &s->harts, TYPE_RISCV_HART_ARRAY);\n");
    body.push_str("    object_property_set_uint(OBJECT(&s->harts), \"num-harts\",\n");
    body.push_str("                             machine->smp.cpus, &error_abort);\n");
    body.push_str("    object_property_set_str(OBJECT(&s->harts), \"cpu-type\",\n");
    body.push_str("                            machine->cpu_type, &error_abort);\n");
    body.push_str(&format!(
        "    object_property_set_uint(OBJECT(&s->harts), \"resetvec\",\n                             {}, &error_abort);\n",
        hex_ull(mrom_base)
    ));
    body.push_str("    sysbus_realize(SYS_BUS_DEVICE(&s->harts), &error_fatal);\n\n");

    body.push_str("    /* Write the MROM reset vector now that harts are realized. */\n");
    body.push_str("    riscv_setup_rom_reset_vec(machine, &s->harts, start_addr,\n");
    body.push_str(&format!(
        "                              {}, {},\n",
        hex_ull(mrom_base),
        hex_ull(mrom_size)
    ));
    body.push_str("                              info.image_low_addr, fdt_addr);\n\n");

    if !all_peripherals.is_empty() {
        body.push_str("    g6lc_");
        body.push_str(&name);
        body.push_str("_create_peripherals(machine);\n");
    }
    body.push_str("}\n\n");

    body.push_str(&format!(
        "static void g6lc_{name}_machine_class_init(ObjectClass *oc, void *data)\n{{\n"
    ));
    body.push_str("    MachineClass *mc = MACHINE_CLASS(oc);\n");
    body.push_str(&format!(
        "    mc->desc = \"GSys LibreCore {target} generated machine\";\n",
        target = model.target_id
    ));
    body.push_str(&format!("    mc->init = g6lc_{name}_machine_init;\n"));
    body.push_str(&format!(
        "    mc->default_cpu_type = TYPE_G6LC_{upper}_CPU;\n"
    ));
    let total = model.soc.harts_total.max(1);
    body.push_str(&format!("    mc->max_cpus = {total};\n"));
    body.push_str(&format!("    mc->default_cpus = {total};\n"));
    body.push_str(&format!("    mc->min_cpus = {total};\n"));
    body.push_str("}\n\n");

    body.push_str(&format!(
        "static const TypeInfo g6lc_{name}_machine_type_info = {{\n"
    ));
    body.push_str(&format!("    .name = TYPE_G6LC_{upper}_MACHINE,\n"));
    body.push_str("    .parent = TYPE_MACHINE,\n");
    body.push_str(&format!(
        "    .instance_size = sizeof({upper}MachineState),\n"
    ));
    body.push_str(&format!(
        "    .class_init = g6lc_{name}_machine_class_init,\n"
    ));
    body.push_str("};\n\n");

    body.push_str(&format!(
        "static void g6lc_{name}_machine_register_types(void)\n{{\n"
    ));
    body.push_str("    type_register_static(&g6lc_");
    body.push_str(&name);
    body.push_str("_machine_type_info);\n}\n\n");

    body.push_str("type_init(g6lc_");
    body.push_str(&name);
    body.push_str("_machine_register_types)\n");

    emission.push(EmittedFile::new(
        format!("hw/riscv/g6lc-{name}-machine.c"),
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
    fn emitted_machine_has_gpl_header_and_machine_type() {
        let mut m = TargetModel::new("g6lc64_test");
        m.soc.harts_total = 4;
        m.soc.intc_sources = 16;
        m.soc.intc_targets = 16;
        m.soc.contexts_per_hart = 1;
        m.soc.dram = Some((0x8000_0000, 0x4000_0000));
        m.soc.bootrom = Some((0x1000, 0xf000));
        m.soc.peripherals.push(g6q_core::model::Peripheral {
            id: "intc".into(),
            base: 0x0c00_0000,
            len: 0x40_0000,
            model: Some("example,intc0".into()),
            irq: None,
            ..g6q_core::model::Peripheral::default()
        });
        m.soc.peripherals.push(g6q_core::model::Peripheral {
            id: "uart".into(),
            base: 0x1000_0000,
            len: 0x100,
            model: Some("ns16550a".into()),
            irq: Some(1),
            ..g6q_core::model::Peripheral::default()
        });

        let e = emit_machine(&m, "0.1.0", "sha256:abc");
        assert_eq!(e.files.len(), 1);
        let f = &e.files[0];
        assert!(f.header_is_valid());
        assert!(f.contents.contains("TYPE_G6LC_G6LC64_TEST_MACHINE"));
        assert!(f.contents.contains("0x80000000ULL"));
        assert!(f.contents.contains("0x10000000ULL"));
        assert!(f.contents.contains("\"uart\""));
        assert!(f.contents.contains("mc->max_cpus = 4"));
        assert!(f.contents.contains("TYPE_G6LC_G6LC64_TEST_CPU"));
        assert!(f
            .contents
            .contains("mc->default_cpu_type = TYPE_G6LC_G6LC64_TEST_CPU"));
        assert!(f.contents.contains("g6lc_g6lc64_test_machine_self_check"));
        assert!(f.contents.contains("g_assert(g6lc_harts_total <="));
        assert!(f.contents.contains("g6lc_g6lc64_test_create_peripherals"));
        assert!(f.contents.contains("qdev_new(qom)"));
        assert!(f.contents.contains("return \"serial-mm\""));
        assert!(f.contents.contains("return \"riscv.sifive.plic\""));
        assert!(f.contents.contains("sifive_plic_create("));
        assert!(f.contents.contains("g6lc_intc_sources"));
        assert!(f.contents.contains("qdev_prop_set_chr"));
        assert!(f.contents.contains("\"ns16550a\", 1"));
        assert!(f.contents.contains("sysbus_connect_irq"));
        assert!(f.contents.contains("qdev_get_gpio_in(plic_dev,"));
        assert!(f.contents.contains("g6lc_peripherals[i].irq"));
        assert!(f.contents.contains("RISCVHartArrayState harts"));
        assert!(f.contents.contains("TYPE_RISCV_HART_ARRAY"));
        assert!(f.contents.contains("riscv_load_kernel"));
        assert!(
            !f.contents.contains("xlnx.xps-spi"),
            "SPI is only emitted when the model has an xps-spi peripheral"
        );
        assert!(f.contents.contains("dram_base + 0x200000ULL"));
        assert!(f.contents.contains("S-mode payloads"));
        assert!(f.contents.contains("riscv_compute_fdt_addr"));
        assert!(f.contents.contains("riscv_load_fdt"));
        assert!(f.contents.contains("fdt_open_into"));
        let fdt_pos = f
            .contents
            .find("g6lc_g6lc64_test_dtb")
            .expect("embedded dtb");
        let kernel_pos = f
            .contents
            .find("riscv_load_kernel")
            .expect("riscv_load_kernel");
        assert!(
            fdt_pos < kernel_pos,
            "FDT must exist before riscv_load_kernel so -initrd sets linux,initrd-*"
        );
        assert!(f
            .contents
            .contains("object_property_set_uint(OBJECT(&s->harts)"));
        assert!(f
            .contents
            .contains("object_property_set_str(OBJECT(&s->harts)"));
        assert!(f
            .contents
            .contains("sysbus_realize(SYS_BUS_DEVICE(&s->harts)"));
        assert!(f.contents.contains("g6lc.mrom"));
        assert!(f.contents.contains("0x1000ULL"));
        assert!(f.contents.contains("0xf000ULL"));
        assert!(f.contents.contains("riscv_find_and_load_firmware"));
        assert!(f.contents.contains("riscv_setup_rom_reset_vec"));
        assert!(f.contents.contains("g6lc_g6lc64_test_machine_fdt_check"));
        assert!(f.contents.contains("fdt_path_offset(fdt, \"/cpus\")"));
        assert!(f.contents.contains("fdt_for_each_subnode"));
    }

    #[test]
    fn machine_uses_default_dram_when_model_has_none() {
        let m = TargetModel::new("t");
        let e = emit_machine(&m, "0.1.0", "sha256:abc");
        assert!(e.files[0].contents.contains("dram_base = 0x80000000ULL"));
    }

    #[test]
    fn machine_without_bootrom_uses_reset_vector_in_mrom() {
        let mut m = TargetModel::new("t");
        m.soc.dram = Some((0x8000_0000, 0x4000_0000));
        let e = emit_machine(&m, "0.1.0", "sha256:abc");
        let f = &e.files[0];
        assert!(f.contents.contains("g6lc.mrom"));
        assert!(f.contents.contains("No firmware requested"));
        assert!(f.contents.contains("info.image_low_addr"));
        assert!(f.contents.contains("riscv_setup_rom_reset_vec"));
    }

    #[test]
    fn machine_emits_xilinx_spi_and_n25q256a_when_model_has_xps_spi() {
        let mut m = TargetModel::new("g6lc64_test");
        m.soc.dram = Some((0x8000_0000, 0x4000_0000));
        m.soc.harts_total = 1;
        m.soc.intc_sources = 4;
        m.soc.intc_targets = 4;
        m.soc.contexts_per_hart = 1;
        m.soc.peripherals.push(g6q_core::model::Peripheral {
            id: "interrupt-controller".into(),
            base: 0x0c00_0000,
            len: 0x0400_0000,
            model: Some("sifive,plic-1.0.0".into()),
            irq: None,
            ..g6q_core::model::Peripheral::default()
        });
        m.soc.peripherals.push(g6q_core::model::Peripheral {
            id: "spi".into(),
            base: 0x2000_0000,
            len: 0x1000,
            model: Some("xlnx,xps-spi-2.00.a".into()),
            irq: Some(2),
            ..g6q_core::model::Peripheral::default()
        });
        let e = emit_machine(&m, "0.1.0", "sha256:abc");
        let f = &e.files[0];
        assert!(f.contents.contains("xlnx.xps-spi"), "{}", f.contents);
        assert!(f.contents.contains("n25q256a"));
        assert!(f.contents.contains("IF_MTD"));
        assert!(f.contents.contains("#include \"hw/ssi/ssi.h\""));
    }

    #[test]
    fn machine_emits_virtio_mmio_transports_when_requested() {
        let mut m = TargetModel::new("g6lc64_test");
        m.soc.dram = Some((0x8000_0000, 0x4000_0000));
        m.soc.virtio_mmio = 2;
        m.soc.intc_sources = 4;
        m.soc.intc_targets = 4;
        m.soc.contexts_per_hart = 1;
        m.soc.harts_total = 1;

        let e = emit_machine(&m, "0.1.0", "sha256:abc");
        let f = &e.files[0];
        assert!(f.contents.contains("\"virtio0\""));
        assert!(f.contents.contains("\"virtio1\""));
        assert!(f.contents.contains("\"virtio-mmio\""));
        assert!(f.contents.contains("return \"virtio-mmio\""));
        assert!(
            f.contents.contains("qdev_new(\"virtio-mmio\")"),
            "generated machine must instantiate the virtio-mmio transport"
        );
        assert!(
            f.contents.contains("sysbus_connect_irq") && f.contents.contains("virtio"),
            "virtio-mmio transport must have an IRQ wired to the PLIC"
        );
    }
}
