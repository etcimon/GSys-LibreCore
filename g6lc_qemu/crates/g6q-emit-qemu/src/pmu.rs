// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! B2 generated QEMU PMU counter plugin.
//!
//! Emits a TCG plugin that counts the events the design itself publishes in its
//! performance-counter matrix. The output is text-only, GPL-2.0-or-later, and
//! becomes part of QEMU.
//!
//! This is intentionally a *sampling* counter plugin: it cannot read the guest's
//! `mhpmevent` CSRs, so it maintains the whole published event table and writes a
//! per-hart counter file at exit. A later pass can map the live `mhpmevent`
//! values to this table through a QEMU helper or a tandem reference.

use g6q_core::model::TargetModel;

use crate::{Emission, EmittedFile};

/// Emit a PMU counter plugin for the model's published event table.
pub fn emit_pmu_plugin(model: &TargetModel, version: &str, digest: &str) -> Emission {
    let name = &model.target_id;
    let harts = model.soc.harts_total.max(1);
    let counter_count = model.pmu.counter_count.max(1) as usize;
    let event_count = model.pmu.events.len().max(1);

    let mut body = String::new();
    body.push_str("#include <stdint.h>\n");
    body.push_str("#include <stdio.h>\n");
    body.push_str("#include <string.h>\n");
    body.push_str("#include <inttypes.h>\n");
    body.push_str("#include <glib.h>\n");
    body.push_str("#include <qemu-plugin.h>\n\n");

    body.push_str(&format!("#define G6LC_TARGET_ID \"{name}\"\n"));
    body.push_str(&format!("#define G6LC_HARTS_TOTAL {harts}u\n"));
    body.push_str(&format!("#define G6LC_PMU_COUNTERS {counter_count}u\n"));
    body.push_str(&format!("#define G6LC_PMU_EVENTS {event_count}u\n\n"));

    body.push_str("/* Event names and selectors from the design's own PMU matrix. */\n");
    body.push_str("static const char *g6lc_pmu_event_name[G6LC_PMU_EVENTS] = {\n");
    for e in &model.pmu.events {
        body.push_str(&format!("    \"{}\",\n", e.name));
    }
    if model.pmu.events.is_empty() {
        body.push_str("    \"unresolved\"\n");
    }
    body.push_str("};\n\n");

    body.push_str("static const uint32_t g6lc_pmu_event_selector[G6LC_PMU_EVENTS] = {\n");
    for e in &model.pmu.events {
        body.push_str(&format!("    {:#010x}u,\n", e.mhpmevent));
    }
    if model.pmu.events.is_empty() {
        body.push_str("    0\n");
    }
    body.push_str("};\n\n");

    body.push_str("/* Per-hart base counters and the published event table. */\n");
    body.push_str("static uint64_t g6lc_pmu_value[G6LC_HARTS_TOTAL][G6LC_PMU_EVENTS];\n");
    body.push_str("static uint64_t g6lc_pmu_cycle[G6LC_HARTS_TOTAL];\n");
    body.push_str("static uint64_t g6lc_pmu_insn[G6LC_HARTS_TOTAL];\n");
    body.push_str("static FILE *g6lc_pmu_file;\n\n");

    body.push_str("/* The plugin cannot read the guest's mhpmevent, so cycles and instructions\n");
    body.push_str(" * are synthetic (one per retired insn).  Other event rows stay at zero\n");
    body.push_str(" * unless a later pass maps them to a sampled signal. */\n");
    body.push_str("static uint64_t g6lc_pmu_event_value(uint32_t hart, uint32_t event_idx)\n{\n");
    body.push_str("    const char *name = g6lc_pmu_event_name[event_idx];\n");
    body.push_str("    if (strcmp(name, \"cycles\") == 0 || strcmp(name, \"mcycle\") == 0) {\n");
    body.push_str("        return g6lc_pmu_cycle[hart];\n");
    body.push_str("    }\n");
    body.push_str("    if (strcmp(name, \"instructions\") == 0 ||\n");
    body.push_str("        strcmp(name, \"minstret\") == 0 ||\n");
    body.push_str("        strcmp(name, \"retired_instructions\") == 0) {\n");
    body.push_str("        return g6lc_pmu_insn[hart];\n");
    body.push_str("    }\n");
    body.push_str("    return g6lc_pmu_value[hart][event_idx];\n");
    body.push_str("}\n\n");

    body.push_str("static void g6lc_pmu_insn_exec(unsigned int vcpu_index, void *userdata)\n{\n");
    body.push_str("    (void)userdata;\n");
    body.push_str("    if (vcpu_index < G6LC_HARTS_TOTAL) {\n");
    body.push_str("        g6lc_pmu_insn[vcpu_index]++;\n");
    body.push_str("        g6lc_pmu_cycle[vcpu_index]++;\n");
    body.push_str("    }\n");
    body.push_str("}\n\n");

    body.push_str(
        "static void g6lc_pmu_tb_trans(qemu_plugin_id_t id, struct qemu_plugin_tb *tb)\n{\n",
    );
    body.push_str("    (void)id;\n");
    body.push_str("    size_t n = qemu_plugin_tb_n_insns(tb);\n");
    body.push_str("    for (size_t i = 0; i < n; ++i) {\n");
    body.push_str("        struct qemu_plugin_insn *insn = qemu_plugin_tb_get_insn(tb, i);\n");
    body.push_str("        qemu_plugin_register_vcpu_insn_exec_cb(\n");
    body.push_str("            insn, g6lc_pmu_insn_exec, QEMU_PLUGIN_CB_NO_REGS, NULL);\n");
    body.push_str("    }\n");
    body.push_str("}\n\n");

    body.push_str("static void g6lc_pmu_atexit(qemu_plugin_id_t id, void *userdata)\n{\n");
    body.push_str("    (void)id;\n");
    body.push_str("    (void)userdata;\n");
    body.push_str("    if (g6lc_pmu_file) {\n");
    body.push_str("        fprintf(g6lc_pmu_file, \"{\\\"header\\\":{\\\"profile\\\":\\\"g6lc-%s\\\",\\\"counter_count\\\":%u},\\\"harts\\\":[\\n\", G6LC_TARGET_ID, G6LC_PMU_COUNTERS);\n");
    body.push_str("        for (uint32_t h = 0; h < G6LC_HARTS_TOTAL; ++h) {\n");
    body.push_str("            if (h != 0) { fprintf(g6lc_pmu_file, \",\\n\"); }\n");
    body.push_str("            fprintf(g6lc_pmu_file, \"  {\\\"hart\\\":%u,\\\"cycles\\\":%\" PRIu64 \",\\\"instructions\\\":%\" PRIu64 \",\\\"events\\\":[\", h, g6lc_pmu_cycle[h], g6lc_pmu_insn[h]);\n");
    body.push_str("            for (uint32_t e = 0; e < G6LC_PMU_EVENTS; ++e) {\n");
    body.push_str("                if (e != 0) { fprintf(g6lc_pmu_file, \",\"); }\n");
    body.push_str("                fprintf(g6lc_pmu_file, \"{\\\"name\\\":\\\"%s\\\",\\\"selector\\\":%u,\\\"value\\\":%\" PRIu64 \"}\",\n");
    body.push_str("                    g6lc_pmu_event_name[e], g6lc_pmu_event_selector[e], g6lc_pmu_event_value(h, e));\n");
    body.push_str("            }\n");
    body.push_str("            fprintf(g6lc_pmu_file, \"]}\");\n");
    body.push_str("        }\n");
    body.push_str("        fprintf(g6lc_pmu_file, \"\\n]}\\n\");\n");
    body.push_str("        fclose(g6lc_pmu_file);\n");
    body.push_str("        g6lc_pmu_file = NULL;\n");
    body.push_str("    }\n");
    body.push_str("    for (uint32_t i = 0; i < G6LC_HARTS_TOTAL; ++i) {\n");
    body.push_str("        g_autofree gchar *msg = g_strdup_printf(\n");
    body.push_str(
        "            \"[g6lc-%s] hart %u: pmu_cycles=%\" PRIu64 \" pmu_insns=%\" PRIu64 \"\\n\",\n",
    );
    body.push_str("            G6LC_TARGET_ID, i, g6lc_pmu_cycle[i], g6lc_pmu_insn[i]);\n");
    body.push_str("        qemu_plugin_outs(msg);\n");
    body.push_str("    }\n");
    body.push_str("}\n\n");

    body.push_str("QEMU_PLUGIN_EXPORT int qemu_plugin_version = QEMU_PLUGIN_VERSION;\n\n");
    body.push_str("QEMU_PLUGIN_EXPORT int qemu_plugin_install(\n");
    body.push_str("    qemu_plugin_id_t id,\n");
    body.push_str("    const qemu_info_t *info,\n");
    body.push_str("    int argc,\n");
    body.push_str("    char **argv)\n{\n");
    body.push_str("    (void)info;\n");
    body.push_str("    for (int i = 0; i < argc; ++i) {\n");
    body.push_str("        if (strncmp(argv[i], \"out=\", 4) == 0) {\n");
    body.push_str("            g6lc_pmu_file = fopen(argv[i] + 4, \"w\");\n");
    body.push_str("        }\n");
    body.push_str("    }\n");
    body.push_str("    qemu_plugin_register_vcpu_tb_trans_cb(id, g6lc_pmu_tb_trans);\n");
    body.push_str("    qemu_plugin_register_atexit_cb(id, g6lc_pmu_atexit, NULL);\n");
    body.push_str("    return 0;\n");
    body.push_str("}\n");

    let mut emission = Emission::new();
    emission.push(EmittedFile::new(
        format!("contrib/plugins/g6lc-{name}-pmu.c"),
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
    fn emitted_pmu_plugin_has_gpl_header_and_qemu_symbols() {
        let m = g6q_core::model::TargetModel::new("g6lc64_test");
        let e = emit_pmu_plugin(&m, "0.1.0", "sha256:abc");
        assert_eq!(e.files.len(), 1);
        let f = &e.files[0];
        assert!(f.header_is_valid());
        assert!(f.contents.contains("QEMU_PLUGIN_VERSION"));
        assert!(f.contents.contains("qemu_plugin_install"));
        assert!(f.contents.contains("qemu_plugin_register_vcpu_tb_trans_cb"));
        assert!(f.contents.contains("qemu_plugin_register_atexit_cb"));
        assert!(f.contents.contains("g6lc_pmu_tb_trans"));
        assert!(f.contents.contains("g6lc_pmu_atexit"));
        assert!(f.contents.contains("G6LC_PMU_COUNTERS"));
        assert!(f.contents.contains("G6LC_PMU_EVENTS"));
        assert!(f.contents.contains("g6lc_pmu_event_name"));
        assert!(f.contents.contains("g6lc_pmu_value"));
        assert!(f.path.contains("-pmu.c"));
    }

    #[test]
    fn emitted_pmu_plugin_uses_portable_inttypes() {
        let m = g6q_core::model::TargetModel::new("g6lc64_test");
        let e = emit_pmu_plugin(&m, "0.1.0", "sha256:abc");
        let c = &e.files[0].contents;
        assert!(c.contains("#include <inttypes.h>"));
        assert!(c.contains("%\" PRIu64 \""));
        assert!(!c.contains("%\"PRIu64\""));
    }

    #[test]
    fn emitted_pmu_plugin_maps_cycles_and_instructions() {
        let mut m = g6q_core::model::TargetModel::new("g6lc64_test");
        m.pmu.events.push(g6q_core::pmu::PmuEvent {
            name: "instructions".into(),
            group: 0,
            index: 0,
            mhpmevent: 0x00000002,
        });
        m.pmu.events.push(g6q_core::pmu::PmuEvent {
            name: "cycles".into(),
            group: 0,
            index: 1,
            mhpmevent: 0x00000001,
        });
        let e = emit_pmu_plugin(&m, "0.1.0", "sha256:abc");
        let c = &e.files[0].contents;
        assert!(c.contains("g6lc_pmu_event_value(h, e)"));
        assert!(c.contains("\"instructions\""));
        assert!(c.contains("\"cycles\""));
    }
}
