// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! B2 generated QEMU plugin emitter.
//!
//! Emits a TCG plugin that counts retired instructions, memory accesses,
//! loads, stores, memory bytes, and vCPU exits per hart. The output is
//! text-only, GPL-2.0-or-later, and becomes part of QEMU.
//!
//! The emitted plugin uses the v4+ TCG plugin API: a translation-block
//! callback instruments every instruction to register per-instruction
//! execution and memory callbacks.

use g6q_core::model::TargetModel;

use crate::machine::machine_name;
use crate::{Emission, EmittedFile};

/// Fields the tensor event carries, in the order the artifact renders them.
///
/// The names are the descriptor package's own field names; a field the layout does not
/// name is emitted as zero rather than omitted, so the artifact shape is identical across
/// routes and a consumer never has to branch on which backend produced it.
const EVENT_FIELDS: &[&str] = &[
    "op",
    "version",
    "flags",
    "m",
    "n",
    "k",
    "ld_ab",
    "ptr_a",
    "ptr_b",
    "ptr_c",
    "ptr_scale",
    "ptr_done",
    "cluster",
];

/// Emit the descriptor shadow buffer and the submission decoder.
///
/// The plugin sees stores one at a time, so it shadows the descriptor window per hart and
/// emits a submission event when the doorbell field is written. That mirrors what the
/// device model does, which is the point: the two routes must produce the same artifact
/// from the same design geometry, or comparing them is meaningless.
fn emit_descriptor_decoder(body: &mut String, island: &g6q_core::model::AiIslandModel) {
    let layout = &island.desc_layout;
    body.push_str("/* Per-hart descriptor shadow, filled by stores into the latch window. */\n");
    body.push_str("static uint8_t g6lc_desc_shadow[G6LC_HARTS_TOTAL][G6LC_AI_DESC_BYTES];\n");
    body.push_str("static uint64_t g6lc_desc_seen[G6LC_HARTS_TOTAL];\n");
    body.push_str(
        "/* Buffered tensor events, written at exit so completion can update done/status. */\n",
    );
    body.push_str("typedef struct G6lcTensorEvent {\n");
    body.push_str("    uint64_t order;\n");
    body.push_str("    uint32_t hart;\n");
    body.push_str("    uint64_t descriptor_addr;\n");
    body.push_str("    uint64_t op;\n");
    body.push_str("    uint64_t version;\n");
    body.push_str("    uint64_t flags;\n");
    body.push_str("    uint64_t m;\n");
    body.push_str("    uint64_t n;\n");
    body.push_str("    uint64_t k;\n");
    body.push_str("    uint64_t ld_ab;\n");
    body.push_str("    uint64_t ptr_a;\n");
    body.push_str("    uint64_t ptr_b;\n");
    body.push_str("    uint64_t ptr_c;\n");
    body.push_str("    uint64_t ptr_scale;\n");
    body.push_str("    uint64_t ptr_done;\n");
    body.push_str("    uint64_t dtype;\n");
    body.push_str("    uint64_t cluster;\n");
    body.push_str("    uint32_t ticket;\n");
    body.push_str("    uint16_t status;\n");
    body.push_str("    bool done;\n");
    body.push_str(
        "    /* PMU fields are modelled by B3; B2 has no time model, so they stay 0. */\n",
    );
    body.push_str("    uint32_t pmu_r_beats;\n");
    body.push_str("    uint32_t pmu_w_beats;\n");
    body.push_str("    uint32_t pmu_cycles;\n");
    body.push_str("    uint32_t pmu_gbps_x1000;\n");
    body.push_str("} G6lcTensorEvent;\n");
    body.push_str("static GArray *g6lc_tensor_events[G6LC_HARTS_TOTAL];\n");
    body.push_str("static uint32_t g6lc_next_ticket[G6LC_HARTS_TOTAL];\n");

    body.push_str("/* Little-endian read out of the shadow; bounds-checked. */\n");
    body.push_str("static uint64_t g6lc_desc_u64(uint32_t hart, uint64_t off, uint64_t size)\n{\n");
    body.push_str("    uint64_t v = 0;\n");
    body.push_str("    if (off + size > G6LC_AI_DESC_BYTES || size == 0 || size > 8) {\n");
    body.push_str("        return 0;\n");
    body.push_str("    }\n");
    body.push_str("    for (uint64_t i = 0; i < size; i++) {\n");
    body.push_str("        v |= ((uint64_t)g6lc_desc_shadow[hart][off + i]) << (i * 8);\n");
    body.push_str("    }\n");
    body.push_str("    return v;\n");
    body.push_str("}\n\n");

    body.push_str("/* Record one store into the descriptor latch window. */\n");
    body.push_str(
        "static void g6lc_desc_store(uint32_t hart, uint64_t off, uint8_t size, uint64_t value)\n{\n",
    );
    body.push_str("    if (off >= G6LC_AI_DESC_BYTES) { return; }\n");
    body.push_str("    for (uint8_t i = 0; i < size && (off + i) < G6LC_AI_DESC_BYTES; i++) {\n");
    body.push_str("        g6lc_desc_shadow[hart][off + i] = (uint8_t)(value >> (i * 8));\n");
    body.push_str("    }\n");
    body.push_str("    g6lc_desc_seen[hart]++;\n");
    body.push_str("}\n\n");

    // Accessor expressions, one per event field, resolved at emit time.
    body.push_str("/* Emit one submission event, shaped exactly like the native artifact. */\n");
    body.push_str("static void g6lc_desc_submit_at(uint32_t hart, uint64_t reported_addr)\n{\n");
    body.push_str("    if (!g6lc_tensor_file) { return; }\n");

    for name in EVENT_FIELDS {
        let upper = name.to_uppercase();
        if layout.fields.contains_key(*name) {
            body.push_str(&format!(
                "    uint64_t f_{name} = g6lc_desc_u64(hart, G6LC_AI_OFF_{upper}, G6LC_AI_SZ_{upper});\n"
            ));
        } else {
            // Named as zero so the shape is stable; absence is a layout gap, not a value.
            body.push_str(&format!("    uint64_t f_{name} = 0; /* not in layout */\n"));
        }
    }
    body.push_str(
        "    uint64_t f_dtype = (f_flags >> G6LC_AI_DTYPE_SHIFT) & G6LC_AI_DTYPE_MASK;\n",
    );
    body.push_str("    if (g6lc_tensor_events[hart] == NULL) {\n");
    body.push_str("        g6lc_tensor_events[hart] = g_array_sized_new(FALSE, TRUE, sizeof(G6lcTensorEvent), 4);\n");
    body.push_str("    }\n");
    body.push_str("    G6lcTensorEvent ev = {0};\n");
    body.push_str("    ev.order = g6lc_tensor_order++;\n");
    body.push_str("    ev.hart = hart;\n");
    body.push_str("    ev.descriptor_addr = reported_addr;\n");
    body.push_str("    ev.op = f_op;\n");
    body.push_str("    ev.version = f_version;\n");
    body.push_str("    ev.flags = f_flags;\n");
    body.push_str("    ev.m = f_m;\n");
    body.push_str("    ev.n = f_n;\n");
    body.push_str("    ev.k = f_k;\n");
    body.push_str("    ev.ld_ab = f_ld_ab;\n");
    body.push_str("    ev.ptr_a = f_ptr_a;\n");
    body.push_str("    ev.ptr_b = f_ptr_b;\n");
    body.push_str("    ev.ptr_c = f_ptr_c;\n");
    body.push_str("    ev.ptr_scale = f_ptr_scale;\n");
    body.push_str("    ev.ptr_done = f_ptr_done;\n");
    body.push_str("    ev.dtype = f_dtype;\n");
    body.push_str("    ev.cluster = f_cluster;\n");
    body.push_str("    if (ev.cluster == 0 && G6LC_AI_QUEUE_CLUSTER_MAP_LEN > 0) {\n");
    body.push_str("        ev.cluster = g6lc_queue_cluster_map[hart % G6LC_AI_QUEUES];\n");
    body.push_str("    }\n");
    body.push_str("    ev.ticket = g6lc_next_ticket[hart]++;\n");
    body.push_str("    ev.status = 0;\n");
    body.push_str("    ev.done = false;\n");
    body.push_str("    ev.pmu_r_beats = 0;\n");
    body.push_str("    ev.pmu_w_beats = 0;\n");
    body.push_str("    ev.pmu_cycles = 0;\n");
    body.push_str("    ev.pmu_gbps_x1000 = 0;\n");
    body.push_str("    g_array_append_val(g6lc_tensor_events[hart], ev);\n");
    body.push_str("}\n\n");

    body.push_str("/* Write one buffered tensor event in the native artifact order. */\n");
    body.push_str("static void g6lc_tensor_event_write(const G6lcTensorEvent *e)\n{\n");
    body.push_str("    if (!g6lc_tensor_file) { return; }\n");
    body.push_str("    if (!g6lc_tensor_first_record) {\n");
    body.push_str("        fprintf(g6lc_tensor_file, \",\\n\");\n");
    body.push_str("    }\n");
    body.push_str("    g6lc_tensor_first_record = false;\n");
    body.push_str(r#"    fprintf(g6lc_tensor_file, "{\"order\":%" PRIu64 ",\"hart\":%u,\"descriptor_addr\":%" PRIu64 ",\"op\":%" PRIu64 ",\"version\":%" PRIu64 ",\"flags\":%" PRIu64 ",\"m\":%" PRIu64 ",\"n\":%" PRIu64 ",\"k\":%" PRIu64 ",\"ld_ab\":%" PRIu64 ",\"ptr_a\":%" PRIu64 ",\"ptr_b\":%" PRIu64 ",\"ptr_c\":%" PRIu64 ",\"ptr_scale\":%" PRIu64 ",\"ptr_done\":%" PRIu64 ",\"dtype\":%" PRIu64 ",\"cluster\":%" PRIu64 ",\"ticket\":%u,\"status\":%u,\"done\":%s,\"pmu_r_beats\":%u,\"pmu_w_beats\":%u,\"pmu_cycles\":%u,\"pmu_gbps_x1000\":%u}", e->order, e->hart, e->descriptor_addr, e->op, e->version, e->flags, e->m, e->n, e->k, e->ld_ab, e->ptr_a, e->ptr_b, e->ptr_c, e->ptr_scale, e->ptr_done, e->dtype, e->cluster, e->ticket, e->status, e->done ? "true" : "false", e->pmu_r_beats, e->pmu_w_beats, e->pmu_cycles, e->pmu_gbps_x1000);"#);
    body.push('\n');
    body.push_str("    fflush(g6lc_tensor_file);\n");
    body.push_str("}\n\n");
    body.push_str("/* Mark an in-flight event done when the guest writes its ptr_done word. */\n");
    body.push_str("static void g6lc_tensor_complete_by_ptr_done(uint32_t hart, uint64_t paddr, uint64_t word)\n{\n");
    body.push_str("    if (hart >= G6LC_HARTS_TOTAL) { return; }\n");
    body.push_str("    GArray *arr = g6lc_tensor_events[hart];\n");
    body.push_str("    if (!arr) { return; }\n");
    body.push_str("    for (gsize i = 0; i < arr->len; ++i) {\n");
    body.push_str("        G6lcTensorEvent *e = &g_array_index(arr, G6lcTensorEvent, i);\n");
    body.push_str("        if (e->done || e->ptr_done != paddr) { continue; }\n");
    body.push_str("#if G6LC_AI_COMPLETION_DECODE == 1\n");
    body.push_str("        uint32_t read_ticket = (uint32_t)(\n");
    body.push_str("            (word >> G6LC_AI_COMPLETION_TICKET_BIT_LOW) &\n");
    body.push_str("            ((1ULL << (G6LC_AI_COMPLETION_TICKET_BIT_HIGH - G6LC_AI_COMPLETION_TICKET_BIT_LOW + 1)) - 1));\n");
    body.push_str("        uint16_t read_status = (uint16_t)(\n");
    body.push_str("            (word >> G6LC_AI_COMPLETION_STATUS_BIT_LOW) &\n");
    body.push_str("            ((1ULL << (G6LC_AI_COMPLETION_STATUS_BIT_HIGH - G6LC_AI_COMPLETION_STATUS_BIT_LOW + 1)) - 1));\n");
    body.push_str("        if (read_ticket == e->ticket && read_status == G6LC_AI_ST_OK) {\n");
    body.push_str("            e->done = true;\n");
    body.push_str("            e->status = read_status;\n");
    body.push_str("        }\n");
    body.push_str("#else\n");
    body.push_str("        e->done = true;\n");
    body.push_str("        e->status = G6LC_AI_ST_OK;\n");
    body.push_str("#endif\n");
    body.push_str("    }\n");
    body.push_str("}\n\n");
}

/// Emit the queue-instruction submission path.
///
/// A guest may submit work without ever storing to the island's latch window: the custom
/// enqueue instruction takes a descriptor pointer in a register and the descriptor itself
/// lives in guest memory. Those submissions are invisible to a memory callback on the
/// island region, so the plugin has to recognise the instruction instead.
///
/// The recognition is entirely architecture-derived: the mask and match value come from
/// the ingested instruction set, so a design that moves the encoding moves this with it.
fn emit_queue_instruction_path(body: &mut String) {
    body.push_str("/* Exec callback for a recognised enqueue instruction. */\n");
    body.push_str("static void g6lc_ai_enq_exec(unsigned int vcpu_index, void *userdata)\n{\n");
    body.push_str("    if (!g6lc_tensor_file || vcpu_index >= G6LC_HARTS_TOTAL) { return; }\n");
    body.push_str("    uint8_t rs1 = (uint8_t)(uintptr_t)userdata;\n");
    body.push_str("    uint64_t desc_addr = 0;\n");
    body.push_str(
        "    if (!g6lc_read_xreg(vcpu_index, rs1, &desc_addr) || desc_addr == 0) { return; }\n",
    );
    body.push_str("    /* The descriptor lives in guest memory, not in the MMIO window. */\n");
    body.push_str("    GByteArray *buf = g_byte_array_new();\n");
    body.push_str(
        "    if (qemu_plugin_read_memory_vaddr(desc_addr, buf, G6LC_AI_DESC_BYTES) &&\n        buf->len >= G6LC_AI_DESC_BYTES) {\n",
    );
    body.push_str("        memcpy(g6lc_desc_shadow[vcpu_index], buf->data, G6LC_AI_DESC_BYTES);\n");
    body.push_str("        /* Guest-physical descriptor address, matching the native artifact.\n");
    body.push_str("         * The MMIO-latch path reports an island-window offset; a descriptor\n");
    body.push_str("         * submitted by pointer is in DRAM and has no window offset, so the\n");
    body.push_str("         * address is reported as-is rather than relative to the island. */\n");
    body.push_str("        g6lc_desc_submit_at(vcpu_index, desc_addr);\n");
    body.push_str("    }\n");
    body.push_str("    g_byte_array_free(buf, TRUE);\n");
    body.push_str("}\n\n");
}

/// Emit the per-vCPU register-access helpers used by the queue-instruction callbacks.
///
/// Kept separate from the enqueue path because the `ai.poll` path needs them too: gating
/// them on the enqueue path alone produced a plugin that would not compile for a design
/// that publishes a poll encoding but no enqueue encoding.
fn emit_register_access(body: &mut String) {
    body.push_str("/* Per-vCPU register handles.\n");
    body.push_str(" *\n");
    body.push_str(
        " * The list is per-vCPU (a single global array would be wrong under MTTCG) and\n",
    );
    body.push_str(
        " * it *grows*: at vCPU-init time qemu_plugin_get_registers() returns only the\n",
    );
    body.push_str(" * CSR features, so the general-purpose registers this path needs are simply\n");
    body.push_str(
        " * absent from it. A cached list is therefore only authoritative for the names\n",
    );
    body.push_str(" * it actually contains, and a lookup miss re-fetches instead of failing.\n");
    body.push_str(" *\n");
    body.push_str(" * Caching a miss is the trap: the failure mode is that queue-instruction\n");
    body.push_str(" * events are silently absent from the artifact, which reads as \"the guest\n");
    body.push_str(" * submitted no work\" rather than as a plugin defect.\n");
    body.push_str(" */\n");
    body.push_str("static GArray *g6lc_regs[G6LC_HARTS_TOTAL];\n\n");

    // Canonical RISC-V register names, index order. This is an ISA-level naming fact,
    // not a design contract, and QEMU exposes registers under these names rather than
    // as `xN` -- so both spellings are tried.
    body.push_str("static const char *const g6lc_xreg_names[32] = {\n");
    body.push_str("    \"zero\", \"ra\", \"sp\", \"gp\", \"tp\", \"t0\", \"t1\", \"t2\",\n");
    body.push_str("    \"s0\", \"s1\", \"a0\", \"a1\", \"a2\", \"a3\", \"a4\", \"a5\",\n");
    body.push_str("    \"a6\", \"a7\", \"s2\", \"s3\", \"s4\", \"s5\", \"s6\", \"s7\",\n");
    body.push_str("    \"s8\", \"s9\", \"s10\", \"s11\", \"t3\", \"t4\", \"t5\", \"t6\"\n");
    body.push_str("};\n\n");

    body.push_str("/* Find and read x[idx] in one register list. */\n");
    body.push_str("static bool g6lc_find_xreg(GArray *regs, uint8_t idx, uint64_t *out)\n{\n");
    body.push_str("    char alt[8];\n");
    body.push_str("    if (!regs) { return false; }\n");
    body.push_str("    snprintf(alt, sizeof(alt), \"x%u\", (unsigned)idx);\n");
    body.push_str("    for (guint r = 0; r < regs->len; r++) {\n");
    body.push_str(
        "        qemu_plugin_reg_descriptor *d =\n            &g_array_index(regs, qemu_plugin_reg_descriptor, r);\n",
    );
    body.push_str("        if (!d->name) { continue; }\n");
    body.push_str("        if (strcmp(d->name, g6lc_xreg_names[idx]) != 0 &&\n");
    body.push_str("            strcmp(d->name, alt) != 0) { continue; }\n");
    body.push_str("        GByteArray *buf = g_byte_array_new();\n");
    body.push_str("        int n = qemu_plugin_read_register(d->handle, buf);\n");
    body.push_str("        bool ok = false;\n");
    body.push_str("        if (n > 0) {\n");
    body.push_str("            uint64_t v = 0;\n");
    body.push_str("            int lim = n > 8 ? 8 : n;\n");
    body.push_str("            for (int b = 0; b < lim; b++) {\n");
    body.push_str("                v |= ((uint64_t)buf->data[b]) << (b * 8);\n");
    body.push_str("            }\n");
    body.push_str("            *out = v;\n");
    body.push_str("            ok = true;\n");
    body.push_str("        }\n");
    body.push_str("        g_byte_array_free(buf, TRUE);\n");
    body.push_str("        return ok;\n");
    body.push_str("    }\n");
    body.push_str("    return false;\n");
    body.push_str("}\n\n");

    body.push_str("/* Resolve this vCPU's register list; safe to call more than once. */\n");
    body.push_str("static void g6lc_resolve_regs(unsigned int vcpu_index)\n{\n");
    body.push_str("    if (vcpu_index >= G6LC_HARTS_TOTAL || g6lc_regs[vcpu_index]) { return; }\n");
    body.push_str("    GArray *regs = qemu_plugin_get_registers();\n");
    body.push_str("    if (regs && regs->len > 0) {\n");
    body.push_str("        g6lc_regs[vcpu_index] = regs;\n");
    body.push_str("    } else if (regs) {\n");
    body.push_str("        g_array_free(regs, TRUE);\n");
    body.push_str("    }\n");
    body.push_str("}\n\n");

    body.push_str("/* Read x[idx] for one vCPU. Returns false when unavailable. */\n");
    body.push_str(
        "static bool g6lc_read_xreg(unsigned int vcpu_index, uint8_t idx, uint64_t *out)\n{\n",
    );
    body.push_str("    GArray *fresh;\n");
    body.push_str("    if (idx == 0) { *out = 0; return true; }\n");
    body.push_str("    if (idx >= 32 || vcpu_index >= G6LC_HARTS_TOTAL) { return false; }\n");
    body.push_str("    if (g6lc_find_xreg(g6lc_regs[vcpu_index], idx, out)) { return true; }\n");
    body.push_str("    /* Miss: the cached list predates the general-purpose register feature.\n");
    body.push_str("     * Re-fetch and adopt the new list only if it actually answers. */\n");
    body.push_str("    fresh = qemu_plugin_get_registers();\n");
    body.push_str("    if (!fresh) { return false; }\n");
    body.push_str("    if (g6lc_find_xreg(fresh, idx, out)) {\n");
    body.push_str("        if (g6lc_regs[vcpu_index]) {\n");
    body.push_str("            g_array_free(g6lc_regs[vcpu_index], TRUE);\n");
    body.push_str("        }\n");
    body.push_str("        g6lc_regs[vcpu_index] = fresh;\n");
    body.push_str("        return true;\n");
    body.push_str("    }\n");
    body.push_str("    g_array_free(fresh, TRUE);\n");
    body.push_str("    g6lc_warn_no_gpr(idx);\n");
    body.push_str("    return false;\n");
    body.push_str("}\n\n");
}

/// Emit a one-time warning for a register the plugin API cannot reach.
///
/// On the pinned QEMU, `qemu_plugin_get_registers()` is built from `gdb_get_register_list()`,
/// which walks only the *dynamically registered* gdbstub features (`cpu->gdb_regs`). A
/// target's **core** registers — the RISC-V general-purpose file, described by
/// `gdb_core_xml_file` — are never in that list, so `rs1` is unreachable and the
/// queue-instruction submission path yields nothing.
///
/// Without this warning the artifact is simply empty, which reads as "the guest submitted no
/// work" rather than "this backend cannot observe the submission". The in-target B1 device
/// has no such limitation and is the execution reference for the queue path.
fn emit_gpr_warning(body: &mut String) {
    body.push_str("/* Warn once when the plugin API cannot reach a general-purpose register. */\n");
    body.push_str("static void g6lc_warn_no_gpr(uint8_t idx)\n{\n");
    body.push_str("    static bool warned;\n");
    body.push_str("    if (warned) { return; }\n");
    body.push_str("    warned = true;\n");
    body.push_str("    fprintf(stderr,\n");
    body.push_str(
        "            \"[g6lc-\" G6LC_TARGET_ID \"] queue-instruction submissions cannot be \"\n",
    );
    body.push_str(
        "            \"recorded: x%u is not exposed by qemu_plugin_get_registers() on this \"\n",
    );
    body.push_str(
        "            \"QEMU (it lists only dynamically-registered gdbstub features, not the \"\n",
    );
    body.push_str(
        "            \"target's core register file). The tensor artifact will be empty for \"\n",
    );
    body.push_str(
        "            \"work submitted by instruction; use the generated in-target device \"\n",
    );
    body.push_str("            \"(B1) or the native VM (B3) for that path.\\n\",\n");
    body.push_str("            (unsigned)idx);\n");
    body.push_str("}\n\n");
}

/// Emit the queue-fence completion path.
///
/// A queue-fence instruction marks all in-flight tensor events for the current
/// hart as completed. It is recognised by the same architecture-derived encoding
/// as the enqueue instruction, but it does not need register access.
fn emit_qfence_instruction_path(body: &mut String) {
    body.push_str("/* Mark every in-flight tensor event for this hart as completed. */\n");
    body.push_str("static void g6lc_ai_qfence_exec(unsigned int vcpu_index, void *userdata)\n{\n");
    body.push_str("    (void)userdata;\n");
    body.push_str("    if (vcpu_index >= G6LC_HARTS_TOTAL) { return; }\n");
    body.push_str("    if (!g6lc_tensor_events[vcpu_index]) { return; }\n");
    body.push_str("    for (gsize i = 0; i < g6lc_tensor_events[vcpu_index]->len; ++i) {\n");
    body.push_str("        G6lcTensorEvent *e = &g_array_index(g6lc_tensor_events[vcpu_index], G6lcTensorEvent, i);\n");
    body.push_str("        e->done = true;\n");
    body.push_str("        e->status = G6LC_AI_ST_OK;\n");
    body.push_str("    }\n");
    body.push_str("}\n\n");
}

/// Emit the `ai.poll` completion path.
///
/// `ai.poll rd, rs1` carries a ticket in `rs1`. When the instruction is retired the
/// plugin reads the completion word at the event's `ptr_done`, and if it contains the
/// matching ticket and `ST_OK` the event is marked done. This is a heuristic: the guest
/// polls only when it expects completion, and the word itself is the island's own format
/// as published by `make_completion`.
fn emit_poll_instruction_path(body: &mut String) {
    body.push_str("/* On ai.poll, read the completion word for the polled ticket. */\n");
    body.push_str("static void g6lc_ai_poll_exec(unsigned int vcpu_index, void *userdata)\n{\n");
    body.push_str("    if (!g6lc_tensor_file || vcpu_index >= G6LC_HARTS_TOTAL) { return; }\n");
    body.push_str("    if (!g6lc_tensor_events[vcpu_index]) { return; }\n");
    body.push_str("    uint8_t rs1 = (uint8_t)(uintptr_t)userdata;\n");
    body.push_str("    uint64_t ticket = 0;\n");
    body.push_str("    if (!g6lc_read_xreg(vcpu_index, rs1, &ticket)) { return; }\n");
    body.push_str("    for (gsize i = 0; i < g6lc_tensor_events[vcpu_index]->len; ++i) {\n");
    body.push_str("        G6lcTensorEvent *e = &g_array_index(g6lc_tensor_events[vcpu_index], G6lcTensorEvent, i);\n");
    body.push_str(
        "        if (e->done || e->ticket != (uint32_t)ticket || e->ptr_done == 0) { continue; }\n",
    );
    body.push_str("        GByteArray *buf = g_byte_array_new();\n");
    body.push_str(
        "        if (qemu_plugin_read_memory_vaddr(e->ptr_done, buf, 8) && buf->len == 8) {\n",
    );
    body.push_str("            uint64_t word = 0;\n");
    body.push_str("            for (int b = 0; b < 8; ++b) { word |= ((uint64_t)buf->data[b]) << (b * 8); }\n");
    body.push_str("            uint32_t read_ticket = (uint32_t)(\n");
    body.push_str("                (word >> G6LC_AI_COMPLETION_TICKET_BIT_LOW) &\n");
    body.push_str("                ((1ULL << (G6LC_AI_COMPLETION_TICKET_BIT_HIGH - G6LC_AI_COMPLETION_TICKET_BIT_LOW + 1)) - 1));\n");
    body.push_str("            uint16_t read_status = (uint16_t)(\n");
    body.push_str("                (word >> G6LC_AI_COMPLETION_STATUS_BIT_LOW) &\n");
    body.push_str("                ((1ULL << (G6LC_AI_COMPLETION_STATUS_BIT_HIGH - G6LC_AI_COMPLETION_STATUS_BIT_LOW + 1)) - 1));\n");
    body.push_str(
        "            if (read_ticket == (uint32_t)ticket && read_status == G6LC_AI_ST_OK) {\n",
    );
    body.push_str("                e->done = true;\n");
    body.push_str("                e->status = read_status;\n");
    body.push_str("            }\n");
    body.push_str("        }\n");
    body.push_str("        g_byte_array_free(buf, TRUE);\n");
    body.push_str("    }\n");
    body.push_str("}\n\n");
}

/// Emit a B2 TCG instrumentation plugin.
pub fn emit_plugin(model: &TargetModel, version: &str, digest: &str) -> Emission {
    let name = machine_name(&model.target_id);

    let mut body = String::new();
    body.push_str("#include \"qemu/osdep.h\"\n");
    body.push_str("#include \"qemu/plugin.h\"\n");
    body.push_str("#include \"qemu/qemu-plugin.h\"\n");
    body.push_str("#include <stdio.h>\n");
    body.push_str("#include <string.h>\n");
    body.push_str("#include <inttypes.h>\n");
    body.push('\n');

    body.push_str(&format!(
        "#define G6LC_TARGET_ID \"{target}\"\n",
        target = model.target_id
    ));
    body.push_str(&format!(
        "#define G6LC_PROFILE \"{profile}\"\n",
        profile = model.profile.as_str()
    ));
    body.push_str(&format!(
        "#define G6LC_PROFILE_TAINTED \"{tainted}\"\n",
        tainted = if model.diagnosable() { "false" } else { "true" }
    ));
    body.push_str(&format!(
        "#define G6LC_HARTS_TOTAL {harts}\n",
        harts = model.soc.harts_total.max(1)
    ));

    let ai = model.soc.peripherals.iter().find(|p| {
        p.id == "ai-island"
            || p.id == "ai_matrix"
            || p.model.as_deref().unwrap_or("").contains("ai-island")
            || p.model.as_deref().unwrap_or("").contains("ai-matrix")
    });
    if let Some(ai) = ai {
        body.push_str(&format!(
            "#define G6LC_AI_ISLAND_BASE 0x{:016x}ULL\n",
            ai.base
        ));
        body.push_str(&format!(
            "#define G6LC_AI_ISLAND_LEN 0x{:016x}ULL\n",
            ai.len
        ));
    } else {
        body.push_str("#define G6LC_AI_ISLAND_BASE 0\n");
        body.push_str("#define G6LC_AI_ISLAND_LEN 0\n");
    }

    // Descriptor geometry, entirely from the ingested layout. When the design does not
    // publish enough to reassemble a descriptor, G6LC_AI_DESC_DECODE is 0 and the plugin
    // falls back to reporting accesses -- it never guesses a layout, because a wrong
    // layout produces plausible-looking wrong tensor events (RTL_FEEDBACK.md F1/F4).
    let island = model.soc.ai_island.as_ref();
    let layout = island.map(|i| &i.desc_layout);
    let desc_bytes = layout.map_or(0, |l| l.desc_bytes);
    let desc_base = island.and_then(|i| i.config.desc_base);
    let can_decode = desc_bytes > 0
        && desc_base.is_some()
        && layout.is_some_and(|l| !l.fields.is_empty() && l.flags_layout.is_some());
    body.push_str(&format!(
        "#define G6LC_AI_DESC_DECODE {}\n",
        if can_decode { 1 } else { 0 }
    ));
    body.push_str(&format!(
        "#define G6LC_AI_DESC_BYTES {}\n",
        desc_bytes.max(1)
    ));
    body.push_str(&format!(
        "#define G6LC_AI_DESC_BASE 0x{:x}ULL\n",
        desc_base.unwrap_or(0)
    ));
    // One offset macro per field the layout names, so the emitted C references the
    // design's own geometry rather than a stride invented here.
    if let Some(l) = layout {
        for (name, f) in &l.fields {
            body.push_str(&format!(
                "#define G6LC_AI_OFF_{} {}\n",
                name.to_uppercase(),
                f.offset
            ));
            body.push_str(&format!(
                "#define G6LC_AI_SZ_{} {}\n",
                name.to_uppercase(),
                f.size
            ));
        }
        let st_ok = l.status("ST_OK").unwrap_or(0);
        body.push_str(&format!("#define G6LC_AI_ST_OK {st_ok}U\n"));
        if let Some(f) = l.flags_layout {
            body.push_str(&format!("#define G6LC_AI_DTYPE_SHIFT {}\n", f.dtype_shift));
            body.push_str(&format!(
                "#define G6LC_AI_DTYPE_MASK 0x{:x}U\n",
                f.dtype_mask
            ));
            body.push_str(&format!(
                "#define G6LC_AI_PRIO_SHIFT {}\n",
                f.priority_shift
            ));
            body.push_str(&format!(
                "#define G6LC_AI_PRIO_MASK 0x{:x}U\n",
                f.priority_mask
            ));
            body.push_str(&format!("#define G6LC_AI_IRQ_BIT {}\n", f.irq_bit));
        }
    }
    // Completion word layout. Derived from `make_completion` when the package publishes it.
    // Without it, the plugin cannot decode the `ptr_done` word on `ai.poll`.
    let completion = layout.as_ref().and_then(|l| l.completion);
    if let Some(c) = completion {
        body.push_str(&format!(
            "#define G6LC_AI_COMPLETION_TICKET_BIT_LOW {}\n",
            c.ticket_bit_low
        ));
        body.push_str(&format!(
            "#define G6LC_AI_COMPLETION_TICKET_BIT_HIGH {}\n",
            c.ticket_bit_high
        ));
        body.push_str(&format!(
            "#define G6LC_AI_COMPLETION_STATUS_BIT_LOW {}\n",
            c.status_bit_low
        ));
        body.push_str(&format!(
            "#define G6LC_AI_COMPLETION_STATUS_BIT_HIGH {}\n",
            c.status_bit_high
        ));
        body.push_str("#define G6LC_AI_COMPLETION_DECODE 1\n");
    }

    // Queue dispatch: a `cluster` descriptor field wins, then a published
    // queue-to-cluster map.  Without either source the event records `cluster` as
    // unresolved (0), just like the B3 path.
    if let Some(i) = island {
        body.push_str(&format!(
            "#define G6LC_AI_QUEUES {}\n",
            i.config.queues.max(1)
        ));
        if let Some(map) = &i.config.queue_cluster_map {
            body.push_str(&format!(
                "#define G6LC_AI_QUEUE_CLUSTER_MAP_LEN {}\n",
                map.len()
            ));
            let entries = map
                .iter()
                .map(|v| v.to_string())
                .collect::<Vec<_>>()
                .join(", ");
            body.push_str(&format!(
                "static const uint32_t g6lc_queue_cluster_map[{}] = {{ {entries} }};\n",
                map.len()
            ));
        } else {
            body.push_str("#define G6LC_AI_QUEUE_CLUSTER_MAP_LEN 0\n");
        }
    } else {
        body.push_str("#define G6LC_AI_QUEUES 1\n");
        body.push_str("#define G6LC_AI_QUEUE_CLUSTER_MAP_LEN 0\n");
    }

    // Custom enqueue encoding, for submissions that never touch the latch window.
    // Emitted only when the design's instruction set was ingested; a zero mask would
    // match every instruction, so absence disables the path rather than defaulting it.
    let instr = island.map(|i| &i.instr_set);
    let enq_decode = can_decode && instr.is_some_and(|s| s.mask_f7f3op != 0 && s.match_enq != 0);
    let qfence_decode =
        can_decode && instr.is_some_and(|s| s.mask_f7f3op != 0 && s.match_qfence != 0);
    let poll_decode = can_decode
        && completion.is_some()
        && instr.is_some_and(|s| s.mask_f7f3op != 0 && s.match_poll != 0);
    body.push_str(&format!(
        "#define G6LC_AI_ENQ_DECODE {}\n",
        if enq_decode { 1 } else { 0 }
    ));
    body.push_str(&format!(
        "#define G6LC_AI_QFENCE_DECODE {}\n",
        if qfence_decode { 1 } else { 0 }
    ));
    body.push_str(&format!(
        "#define G6LC_AI_POLL_DECODE {}\n",
        if poll_decode { 1 } else { 0 }
    ));
    if let Some(s) = instr {
        body.push_str(&format!(
            "#define G6LC_AI_ENQ_MASK 0x{:08x}U\n",
            s.mask_f7f3op
        ));
        body.push_str(&format!(
            "#define G6LC_AI_ENQ_MATCH 0x{:08x}U\n",
            s.match_enq
        ));
        body.push_str(&format!(
            "#define G6LC_AI_QFENCE_MASK 0x{:08x}U\n",
            s.mask_f7f3op
        ));
        body.push_str(&format!(
            "#define G6LC_AI_QFENCE_MATCH 0x{:08x}U\n",
            s.match_qfence
        ));
        body.push_str(&format!(
            "#define G6LC_AI_POLL_MASK 0x{:08x}U\n",
            s.mask_f7f3op
        ));
        body.push_str(&format!(
            "#define G6LC_AI_POLL_MATCH 0x{:08x}U\n",
            s.match_poll
        ));
    }
    body.push('\n');

    body.push_str(
        "/* Per-hart retired-instruction, memory, MMIO and vCPU-lifecycle counters. */\n",
    );
    body.push_str("static uint64_t g6lc_insn_count[G6LC_HARTS_TOTAL];\n");
    body.push_str("static uint64_t g6lc_load_count[G6LC_HARTS_TOTAL];\n");
    body.push_str("static uint64_t g6lc_store_count[G6LC_HARTS_TOTAL];\n");
    body.push_str("static uint64_t g6lc_mem_count[G6LC_HARTS_TOTAL];\n");
    body.push_str("static uint64_t g6lc_mem_bytes[G6LC_HARTS_TOTAL];\n");
    body.push_str("static uint64_t g6lc_mmio_count[G6LC_HARTS_TOTAL];\n");
    body.push_str("static uint64_t g6lc_ai_island_count[G6LC_HARTS_TOTAL];\n");
    body.push_str("static uint64_t g6lc_init_count[G6LC_HARTS_TOTAL];\n");
    body.push_str("static uint64_t g6lc_idle_count[G6LC_HARTS_TOTAL];\n");
    body.push_str("static uint64_t g6lc_resume_count[G6LC_HARTS_TOTAL];\n");
    body.push_str("static uint64_t g6lc_exit_count[G6LC_HARTS_TOTAL];\n");
    body.push_str("#if G6LC_AI_ISLAND_LEN != 0\n");
    body.push_str("static FILE *g6lc_tensor_file;\n");
    body.push_str("static uint64_t g6lc_tensor_order;\n");
    body.push_str("static bool g6lc_tensor_first_record;\n");
    body.push_str("#if G6LC_AI_DESC_DECODE != 1\n\n");
    body.push_str(
        "/* Geometry unresolved: emit raw AI-island memory accesses as tensor events. */\n",
    );
    body.push_str("static void g6lc_tensor_write(\n");
    body.push_str("    uint32_t hart, uint64_t vaddr, uint64_t paddr,\n");
    body.push_str("    bool is_store, uint8_t size)\n{\n");
    body.push_str("    if (!g6lc_tensor_file) { return; }\n");
    body.push_str("    if (!g6lc_tensor_first_record) {\n");
    body.push_str("        fprintf(g6lc_tensor_file, \",\\n\");\n");
    body.push_str("    }\n");
    body.push_str("    g6lc_tensor_first_record = false;\n");
    body.push_str(r#"    fprintf(g6lc_tensor_file, "{\"order\":%" PRIu64 ",\"hart\":%u,\"vaddr\":%" PRIu64 ",\"paddr\":%" PRIu64 ",\"is_store\":%s,\"size\":%u}", g6lc_tensor_order++, hart, vaddr, paddr, is_store ? "true" : "false", (uint32_t)size);"#);
    body.push('\n');
    body.push_str("    fflush(g6lc_tensor_file);\n");
    body.push_str("}\n");
    body.push_str("#endif\n");
    body.push_str("#endif\n\n");

    if can_decode {
        emit_descriptor_decoder(&mut body, island.expect("can_decode implies an island"));
    }
    if enq_decode || poll_decode {
        emit_gpr_warning(&mut body);
        emit_register_access(&mut body);
    }
    if enq_decode {
        emit_queue_instruction_path(&mut body);
    }
    if qfence_decode {
        emit_qfence_instruction_path(&mut body);
    }
    if poll_decode {
        emit_poll_instruction_path(&mut body);
    }

    body.push_str(
        "/* Optional D1 commit-record trace.  One record per retired instruction, indexed per hart. */\n",
    );
    body.push_str("typedef struct G6lcInsnInfo {\n");
    body.push_str("    uint64_t pc;\n");
    body.push_str("    uint32_t data;\n");
    body.push_str("    uint8_t size;\n");
    body.push_str("} G6lcInsnInfo;\n\n");
    body.push_str("typedef struct G6lcRecord {\n");
    body.push_str("    uint64_t order;\n");
    body.push_str("    uint32_t hart;\n");
    body.push_str("    uint64_t pc_rdata;\n");
    body.push_str("    uint64_t pc_wdata;\n");
    body.push_str("    uint32_t insn;\n");
    body.push_str("    uint8_t size;\n");
    body.push_str("    bool trap;\n");
    body.push_str("    uint64_t cause;\n");
    body.push_str("    uint8_t prv;\n");
    body.push_str("    bool halt;\n");
    body.push_str("    uint8_t rd_addr;\n");
    body.push_str("    uint64_t rd_wdata;\n");
    body.push_str("    uint8_t frd_addr;\n");
    body.push_str("    uint64_t frd_wdata;\n");
    body.push_str("} G6lcRecord;\n\n");
    body.push_str("static FILE *g6lc_trace_file;\n");
    body.push_str("static GPtrArray *g6lc_trace_insns;\n");
    body.push_str("static uint64_t g6lc_trace_order[G6LC_HARTS_TOTAL];\n");
    body.push_str("static G6lcRecord g6lc_trace_prev[G6LC_HARTS_TOTAL];\n");
    body.push_str("static bool g6lc_trace_prev_valid[G6LC_HARTS_TOTAL];\n");
    body.push_str("static bool g6lc_trace_first_record;\n");
    body.push_str("#define G6LC_TRACE_BATCH 65536\n");
    body.push_str("static G6lcRecord g6lc_trace_batch[G6LC_HARTS_TOTAL][G6LC_TRACE_BATCH];\n");
    body.push_str("static size_t g6lc_trace_batch_len[G6LC_HARTS_TOTAL];\n");
    body.push_str("static GMutex g6lc_trace_lock;\n\n");

    body.push_str("static void g6lc_trace_format_record(GString *buf, const G6lcRecord *rec)\n{\n");
    body.push_str("    g_string_append_printf(buf,\n");
    body.push_str("        \"{\\\"order\\\":%\" PRIu64 \",\\\"hart\\\":%u,\\\"pc_rdata\\\":%\" PRIu64 \",\\\"pc_wdata\\\":%\" PRIu64 \",\\\"insn\\\":%\" PRIu32 \",\\\"trap\\\":%s,\\\"cause\\\":%\" PRIu64 \",\\\"prv\\\":%u,\\\"halt\\\":%s,\\\"rd_addr\\\":%u,\\\"rd_wdata\\\":%\" PRIu64 \",\\\"frd_addr\\\":%u,\\\"frd_wdata\\\":%\" PRIu64 \"}\",\n");
    body.push_str("        rec->order, rec->hart,\n");
    body.push_str("        rec->pc_rdata, rec->pc_wdata,\n");
    body.push_str("        rec->insn,\n");
    body.push_str("        rec->trap ? \"true\" : \"false\",\n");
    body.push_str("        rec->cause, rec->prv,\n");
    body.push_str("        rec->halt ? \"true\" : \"false\",\n");
    body.push_str("        rec->rd_addr, rec->rd_wdata,\n");
    body.push_str("        rec->frd_addr, rec->frd_wdata);\n");
    body.push_str("}\n\n");

    body.push_str("static void g6lc_trace_flush(uint32_t hart)\n{\n");
    body.push_str("    if (!g6lc_trace_file || hart >= G6LC_HARTS_TOTAL || g6lc_trace_batch_len[hart] == 0) {\n");
    body.push_str("        return;\n");
    body.push_str("    }\n");
    body.push_str("    GString *body = g_string_sized_new(1 << 24);\n");
    body.push_str("    for (size_t i = 0; i < g6lc_trace_batch_len[hart]; ++i) {\n");
    body.push_str("        if (i > 0) {\n");
    body.push_str("            g_string_append(body, \",\\n\");\n");
    body.push_str("        }\n");
    body.push_str("        g6lc_trace_format_record(body, &g6lc_trace_batch[hart][i]);\n");
    body.push_str("    }\n");
    body.push_str("    g_mutex_lock(&g6lc_trace_lock);\n");
    body.push_str("    if (g6lc_trace_file) {\n");
    body.push_str("        if (!g6lc_trace_first_record) {\n");
    body.push_str("            fwrite(\",\\n\", 1, 2, g6lc_trace_file);\n");
    body.push_str("        } else {\n");
    body.push_str("            g6lc_trace_first_record = false;\n");
    body.push_str("        }\n");
    body.push_str("        fwrite(body->str, 1, body->len, g6lc_trace_file);\n");
    body.push_str("    }\n");
    body.push_str("    g_mutex_unlock(&g6lc_trace_lock);\n");
    body.push_str("    g_string_free(body, TRUE);\n");
    body.push_str("    g6lc_trace_batch_len[hart] = 0;\n");
    body.push_str("}\n\n");

    body.push_str("static void g6lc_trace_write(const G6lcRecord *rec)\n{\n");
    body.push_str("    if (!g6lc_trace_file) {\n");
    body.push_str("        return;\n");
    body.push_str("    }\n");
    body.push_str("    uint32_t hart = rec->hart;\n");
    body.push_str("    if (hart >= G6LC_HARTS_TOTAL) {\n");
    body.push_str("        return;\n");
    body.push_str("    }\n");
    body.push_str("    g6lc_trace_batch[hart][g6lc_trace_batch_len[hart]++] = *rec;\n");
    body.push_str("    if (g6lc_trace_batch_len[hart] == G6LC_TRACE_BATCH) {\n");
    body.push_str("        g6lc_trace_flush(hart);\n");
    body.push_str("    }\n");
    body.push_str("}\n\n");

    body.push_str("static void g6lc_vcpu_insn_exec(unsigned int vcpu_index, void *userdata)\n{\n");
    body.push_str("    G6lcInsnInfo *info = (G6lcInsnInfo *)userdata;\n");
    body.push_str("    if (vcpu_index < G6LC_HARTS_TOTAL) {\n");
    body.push_str("        g6lc_insn_count[vcpu_index]++;\n");
    body.push_str("    }\n");
    body.push_str("    if (!g6lc_trace_file || vcpu_index >= G6LC_HARTS_TOTAL || !info) {\n");
    body.push_str("        return;\n");
    body.push_str("    }\n");
    body.push_str("    uint32_t hart = vcpu_index;\n");
    body.push_str("    uint64_t pc = info->pc;\n");
    body.push_str("    if (g6lc_trace_prev_valid[hart]) {\n");
    body.push_str("        g6lc_trace_prev[hart].pc_wdata = pc;\n");
    body.push_str("        g6lc_trace_prev[hart].halt = false;\n");
    body.push_str("        g6lc_trace_write(&g6lc_trace_prev[hart]);\n");
    body.push_str("    }\n");
    body.push_str("    G6lcRecord rec = {0};\n");
    body.push_str("    rec.order = g6lc_trace_order[hart]++;\n");
    body.push_str("    rec.hart = hart;\n");
    body.push_str("    rec.pc_rdata = pc;\n");
    body.push_str("    rec.pc_wdata = pc + info->size;\n");
    body.push_str("    rec.insn = info->data;\n");
    body.push_str("    rec.size = info->size;\n");
    body.push_str(
        "    /* QEMU plugin API does not expose the current privilege; leave 0 and let */\n",
    );
    body.push_str("    /* a full D1 reference record carry the authoritative prv. */\n");
    body.push_str("    g6lc_trace_prev[hart] = rec;\n");
    body.push_str("    g6lc_trace_prev_valid[hart] = true;\n");
    body.push_str("}\n\n");

    body.push_str("static void g6lc_vcpu_mem_access(\n");
    body.push_str("    unsigned int vcpu_index,\n");
    body.push_str("    qemu_plugin_meminfo_t meminfo,\n");
    body.push_str("    uint64_t vaddr,\n");
    body.push_str("    void *userdata)\n{\n");
    body.push_str("    (void)userdata;\n");
    body.push_str("    if (vcpu_index >= G6LC_HARTS_TOTAL) {\n");
    body.push_str("        return;\n");
    body.push_str("    }\n");
    body.push_str("    g6lc_mem_count[vcpu_index]++;\n");
    body.push_str(
        "    uint8_t g6lc_size = (uint8_t)(1U << qemu_plugin_mem_size_shift(meminfo));\n",
    );
    body.push_str("    g6lc_mem_bytes[vcpu_index] += (uint64_t)g6lc_size;\n");
    body.push_str("    bool g6lc_is_store = qemu_plugin_mem_is_store(meminfo);\n");
    body.push_str("    if (g6lc_is_store) {\n");
    body.push_str("        g6lc_store_count[vcpu_index]++;\n");
    body.push_str("    } else {\n");
    body.push_str("        g6lc_load_count[vcpu_index]++;\n");
    body.push_str("    }\n");
    body.push_str(
        "    struct qemu_plugin_hwaddr *haddr = qemu_plugin_get_hwaddr(meminfo, vaddr);\n",
    );
    body.push_str("    if (haddr && qemu_plugin_hwaddr_is_io(haddr)) {\n");
    body.push_str("        g6lc_mmio_count[vcpu_index]++;\n");
    body.push_str("    }\n");
    body.push_str("#if G6LC_AI_DESC_DECODE == 1 || G6LC_AI_ISLAND_LEN != 0\n");
    body.push_str("    bool is_io = haddr && qemu_plugin_hwaddr_is_io(haddr);\n");
    body.push_str(
        "    uint64_t paddr = (haddr && !is_io) ? qemu_plugin_hwaddr_phys_addr(haddr) : vaddr;\n",
    );
    body.push_str("#endif\n");
    body.push_str("#if G6LC_AI_DESC_DECODE == 1\n");
    body.push_str("    uint64_t store_word = 0;\n");
    body.push_str("    if (g6lc_is_store) {\n");
    body.push_str("        qemu_plugin_mem_value val = qemu_plugin_mem_get_value(meminfo);\n");
    body.push_str("        switch (val.type) {\n");
    body.push_str("        case QEMU_PLUGIN_MEM_VALUE_U8:  store_word = val.data.u8;  break;\n");
    body.push_str("        case QEMU_PLUGIN_MEM_VALUE_U16: store_word = val.data.u16; break;\n");
    body.push_str("        case QEMU_PLUGIN_MEM_VALUE_U32: store_word = val.data.u32; break;\n");
    body.push_str("        case QEMU_PLUGIN_MEM_VALUE_U64: store_word = val.data.u64; break;\n");
    body.push_str("        case QEMU_PLUGIN_MEM_VALUE_U128:\n");
    body.push_str("            store_word = val.data.u128.low; break;\n");
    body.push_str("        default: store_word = 0; break;\n");
    body.push_str("        }\n");
    body.push_str("    }\n");
    body.push_str("    /* Guest writes to a ptr_done address complete that descriptor. */\n");
    body.push_str("    if (g6lc_is_store) {\n");
    body.push_str("        g6lc_tensor_complete_by_ptr_done(vcpu_index, paddr, store_word);\n");
    body.push_str("    }\n");
    body.push_str("#endif\n");
    body.push_str("#if G6LC_AI_ISLAND_LEN != 0\n");
    body.push_str("    {\n");
    body.push_str("        uint64_t off = paddr - G6LC_AI_ISLAND_BASE;\n");
    body.push_str("        if (off < G6LC_AI_ISLAND_LEN) {\n");
    body.push_str("            g6lc_ai_island_count[vcpu_index]++;\n");
    if can_decode {
        body.push_str("            /* Shadow the descriptor latch window and emit one event on\n");
        body.push_str("             * the doorbell write, so this stream carries submissions\n");
        body.push_str("             * rather than raw accesses. */\n");
        body.push_str("            if (g6lc_is_store && off >= G6LC_AI_DESC_BASE &&\n");
        body.push_str("                off < G6LC_AI_DESC_BASE + G6LC_AI_DESC_BYTES) {\n");
        body.push_str("                uint64_t doff = off - G6LC_AI_DESC_BASE;\n");
        body.push_str(
            "                g6lc_desc_store(vcpu_index, doff, g6lc_size, store_word);\n",
        );
        body.push_str(
            "                /* The doorbell is the version/op word at descriptor offset 0. */\n",
        );
        body.push_str("                if (doff == 0) {\n");
        body.push_str(
            "                    /* Latch path: the descriptor is in the island window, so\n\
             \x20                    * the event carries the window-relative offset. */\n",
        );
        body.push_str(
            "                    g6lc_desc_submit_at(vcpu_index,\n\
             \x20                                       paddr - G6LC_AI_ISLAND_BASE);\n",
        );
        body.push_str("                }\n");
        body.push_str("            }\n");
    } else {
        // Geometry unresolved: report accesses. Emitting a decoder here would need a
        // guessed descriptor base (RTL_FEEDBACK.md F1).
        body.push_str("            g6lc_tensor_write(\n");
        body.push_str("                vcpu_index, vaddr, paddr,\n");
        body.push_str("                g6lc_is_store, g6lc_size);\n");
    }
    body.push_str("        }\n");
    body.push_str("    }\n");
    body.push_str("#endif\n");
    body.push_str("}\n\n");

    body.push_str("static void g6lc_vcpu_exit(qemu_plugin_id_t id, unsigned int vcpu_index)\n{\n");
    body.push_str("    (void)id;\n");
    body.push_str("    if (vcpu_index < G6LC_HARTS_TOTAL) {\n");
    body.push_str("        g6lc_exit_count[vcpu_index]++;\n");
    body.push_str("    }\n");
    body.push_str("}\n\n");

    body.push_str("static void g6lc_vcpu_init(qemu_plugin_id_t id, unsigned int vcpu_index)\n{\n");
    body.push_str("    (void)id;\n");
    body.push_str("    if (vcpu_index < G6LC_HARTS_TOTAL) {\n");
    body.push_str("        g6lc_init_count[vcpu_index]++;\n");
    body.push_str("    }\n");
    if enq_decode || poll_decode {
        body.push_str(
            "    /* The only context qemu-plugin.h sanctions for resolving registers. */\n",
        );
        body.push_str("    g6lc_resolve_regs(vcpu_index);\n");
    }
    body.push_str("}\n\n");

    body.push_str("static void g6lc_vcpu_idle(qemu_plugin_id_t id, unsigned int vcpu_index)\n{\n");
    body.push_str("    (void)id;\n");
    body.push_str("    if (vcpu_index < G6LC_HARTS_TOTAL) {\n");
    body.push_str("        g6lc_idle_count[vcpu_index]++;\n");
    body.push_str("    }\n");
    body.push_str("}\n\n");

    body.push_str(
        "static void g6lc_vcpu_resume(qemu_plugin_id_t id, unsigned int vcpu_index)\n{\n",
    );
    body.push_str("    (void)id;\n");
    body.push_str("    if (vcpu_index < G6LC_HARTS_TOTAL) {\n");
    body.push_str("        g6lc_resume_count[vcpu_index]++;\n");
    body.push_str("    }\n");
    body.push_str("}\n\n");

    body.push_str("static void g6lc_tb_trans(qemu_plugin_id_t id, struct qemu_plugin_tb *tb)\n{\n");
    body.push_str("    (void)id;\n");
    body.push_str("    if (g6lc_trace_insns == NULL) {\n");
    body.push_str("        g6lc_trace_insns = g_ptr_array_new();\n");
    body.push_str("        g_ptr_array_set_free_func(g6lc_trace_insns, g_free);\n");
    body.push_str("    }\n");
    body.push_str("    size_t n = qemu_plugin_tb_n_insns(tb);\n");
    body.push_str("    for (size_t i = 0; i < n; ++i) {\n");
    body.push_str("        struct qemu_plugin_insn *insn = qemu_plugin_tb_get_insn(tb, i);\n");
    body.push_str("        G6lcInsnInfo *info = g_new0(G6lcInsnInfo, 1);\n");
    body.push_str("        info->pc = qemu_plugin_insn_vaddr(insn);\n");
    body.push_str("        info->size = (uint8_t)qemu_plugin_insn_size(insn);\n");
    body.push_str("        if (info->size > 4) { info->size = 4; }\n");
    body.push_str("        qemu_plugin_insn_data(insn, &info->data, sizeof(info->data));\n");
    body.push_str("        if (info->size < 4) {\n");
    body.push_str("            info->data &= (uint32_t)((1ULL << (info->size * 8)) - 1);\n");
    body.push_str("        }\n");
    body.push_str("        g_ptr_array_add(g6lc_trace_insns, info);\n");
    if enq_decode {
        body.push_str("        /* Recognise the custom enqueue by the design's own encoding.\n");
        body.push_str("         * The callback needs register access, so it is registered\n");
        body.push_str("         * with QEMU_PLUGIN_CB_R_REGS rather than NO_REGS. */\n");
        body.push_str("        if ((info->data & G6LC_AI_ENQ_MASK) == G6LC_AI_ENQ_MATCH) {\n");
        body.push_str("            uint8_t rs1 = (uint8_t)((info->data >> 15) & 0x1f);\n");
        body.push_str("            qemu_plugin_register_vcpu_insn_exec_cb(\n");
        body.push_str("                insn, g6lc_ai_enq_exec, QEMU_PLUGIN_CB_R_REGS,\n");
        body.push_str("                (void *)(uintptr_t)rs1);\n");
        body.push_str("        }\n");
    }
    if qfence_decode {
        body.push_str("        /* Recognise the queue fence by the design's own encoding.\n");
        body.push_str("         * It only needs to mark in-flight events, so it is registered\n");
        body.push_str("         * with QEMU_PLUGIN_CB_NO_REGS. */\n");
        body.push_str(
            "        if ((info->data & G6LC_AI_QFENCE_MASK) == G6LC_AI_QFENCE_MATCH) {\n",
        );
        body.push_str("            qemu_plugin_register_vcpu_insn_exec_cb(\n");
        body.push_str(
            "                insn, g6lc_ai_qfence_exec, QEMU_PLUGIN_CB_NO_REGS, NULL);\n",
        );
        body.push_str("        }\n");
    }
    if poll_decode {
        body.push_str("        /* Recognise the queue poll by the design's own encoding.\n");
        body.push_str("         * It reads the polled ticket and then the completion word. */\n");
        body.push_str("        if ((info->data & G6LC_AI_POLL_MASK) == G6LC_AI_POLL_MATCH) {\n");
        body.push_str("            uint8_t rs1 = (uint8_t)((info->data >> 15) & 0x1f);\n");
        body.push_str("            qemu_plugin_register_vcpu_insn_exec_cb(\n");
        body.push_str("                insn, g6lc_ai_poll_exec, QEMU_PLUGIN_CB_R_REGS,\n");
        body.push_str("                (void *)(uintptr_t)rs1);\n");
        body.push_str("        }\n");
    }
    body.push_str("        qemu_plugin_register_vcpu_insn_exec_cb(\n");
    body.push_str("            insn, g6lc_vcpu_insn_exec, QEMU_PLUGIN_CB_NO_REGS, info);\n");
    body.push_str("        qemu_plugin_register_vcpu_mem_cb(\n");
    body.push_str("            insn, g6lc_vcpu_mem_access, QEMU_PLUGIN_CB_NO_REGS,\n");
    body.push_str("            QEMU_PLUGIN_MEM_RW, info);\n");
    body.push_str("    }\n");
    body.push_str("}\n\n");

    body.push_str("static void g6lc_atexit(qemu_plugin_id_t id, void *userdata)\n{\n");
    body.push_str("    (void)id;\n");
    body.push_str("    (void)userdata;\n");
    body.push_str("    if (g6lc_trace_file) {\n");
    body.push_str("        for (uint32_t h = 0; h < G6LC_HARTS_TOTAL; ++h) {\n");
    body.push_str("            if (g6lc_trace_prev_valid[h]) {\n");
    body.push_str("                g6lc_trace_prev[h].halt = true;\n");
    body.push_str("                g6lc_trace_write(&g6lc_trace_prev[h]);\n");
    body.push_str("            }\n");
    body.push_str("        }\n");
    body.push_str("        for (uint32_t h = 0; h < G6LC_HARTS_TOTAL; ++h) {\n");
    body.push_str("            g6lc_trace_flush(h);\n");
    body.push_str("        }\n");
    body.push_str("        fprintf(g6lc_trace_file, \"\\n]}\\n\");\n");
    body.push_str("        fclose(g6lc_trace_file);\n");
    body.push_str("        g6lc_trace_file = NULL;\n");
    body.push_str("    }\n");
    body.push_str("#if G6LC_AI_ISLAND_LEN != 0\n");
    body.push_str("    if (g6lc_tensor_file) {\n");
    body.push_str("#if G6LC_AI_DESC_DECODE == 1\n");
    body.push_str("        for (uint32_t h = 0; h < G6LC_HARTS_TOTAL; ++h) {\n");
    body.push_str("            if (g6lc_tensor_events[h]) {\n");
    body.push_str("                for (gsize i = 0; i < g6lc_tensor_events[h]->len; ++i) {\n");
    body.push_str("                    G6lcTensorEvent *ev = &g_array_index(g6lc_tensor_events[h], G6lcTensorEvent, i);\n");
    body.push_str("                    g6lc_tensor_event_write(ev);\n");
    body.push_str("                }\n");
    body.push_str("            }\n");
    body.push_str("        }\n");
    body.push_str("#endif\n");
    body.push_str("        fprintf(g6lc_tensor_file, \"\\n]}\\n\");\n");
    body.push_str("        fclose(g6lc_tensor_file);\n");
    body.push_str("        g6lc_tensor_file = NULL;\n");
    body.push_str("    }\n");
    body.push_str("#if G6LC_AI_DESC_DECODE == 1\n");
    body.push_str("    for (uint32_t h = 0; h < G6LC_HARTS_TOTAL; ++h) {\n");
    body.push_str("        if (g6lc_tensor_events[h]) {\n");
    body.push_str("            g_array_free(g6lc_tensor_events[h], TRUE);\n");
    body.push_str("            g6lc_tensor_events[h] = NULL;\n");
    body.push_str("        }\n");
    body.push_str("    }\n");
    body.push_str("#endif\n");
    body.push_str("#endif\n");
    body.push_str("    if (g6lc_trace_insns) {\n");
    body.push_str("        g_ptr_array_free(g6lc_trace_insns, TRUE);\n");
    body.push_str("        g6lc_trace_insns = NULL;\n");
    body.push_str("    }\n");
    body.push_str("    for (uint32_t i = 0; i < G6LC_HARTS_TOTAL; ++i) {\n");
    body.push_str("        g_autofree gchar *msg = g_strdup_printf(\n");
    body.push_str("            \"[g6lc-%s] hart %u: \"\n");
    body.push_str("            \"insns=%\"PRIu64\" loads=%\"PRIu64\" \"\n");
    body.push_str("            \"stores=%\"PRIu64\" mem=%\"PRIu64\" \"\n");
    body.push_str("            \"mmio=%\"PRIu64\" mem_bytes=%\"PRIu64\" \"\n");
    body.push_str("            \"ai_island=%\"PRIu64\" \"\n");
    body.push_str("            \"inits=%\"PRIu64\" idle=%\"PRIu64\" \"\n");
    body.push_str("            \"resume=%\"PRIu64\" exits=%\"PRIu64\"\\n\",\n");
    body.push_str("            G6LC_TARGET_ID, i, g6lc_insn_count[i],\n");
    body.push_str("            g6lc_load_count[i], g6lc_store_count[i],\n");
    body.push_str("            g6lc_mem_count[i], g6lc_mmio_count[i],\n");
    body.push_str("            g6lc_mem_bytes[i], g6lc_ai_island_count[i],\n");
    body.push_str("            g6lc_init_count[i], g6lc_idle_count[i],\n");
    body.push_str("            g6lc_resume_count[i], g6lc_exit_count[i]);\n");
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
    body.push_str("        if (strncmp(argv[i], \"trace=\", 6) == 0) {\n");
    body.push_str("            const char *path = argv[i] + 6;\n");
    body.push_str("            g6lc_trace_file = fopen(path, \"w\");\n");
    body.push_str("            if (g6lc_trace_file) {\n");
    body.push_str("                g6lc_trace_first_record = true;\n");
    body.push_str("                g_mutex_init(&g6lc_trace_lock);\n");
    body.push_str("                fprintf(g6lc_trace_file,\n");
    body.push_str("                    \"{\\\"header\\\":{\\\"profile\\\":\\\"%s\\\",\\\"profile_tainted\\\":%s,\\\"evidence\\\":false},\\\"records\\\":[\\n\",\n");
    body.push_str("                    G6LC_PROFILE, G6LC_PROFILE_TAINTED);\n");
    body.push_str("            }\n");
    body.push_str("        }\n");
    body.push_str("#if G6LC_AI_ISLAND_LEN != 0\n");
    body.push_str("        if (strncmp(argv[i], \"tensor=\", 7) == 0) {\n");
    body.push_str("            const char *path = argv[i] + 7;\n");
    body.push_str("            g6lc_tensor_file = fopen(path, \"w\");\n");
    body.push_str("            if (g6lc_tensor_file) {\n");
    body.push_str("                g6lc_tensor_first_record = true;\n");
    body.push_str("                g6lc_tensor_order = 0;\n");
    body.push_str("                fprintf(g6lc_tensor_file,\n");
    body.push_str("                    \"{\\\"header\\\":{\\\"profile\\\":\\\"%s\\\",\\\"profile_tainted\\\":%s,\\\"evidence\\\":false}\",\n");
    body.push_str("                    G6LC_PROFILE, G6LC_PROFILE_TAINTED);\n");
    body.push_str("#if G6LC_AI_DESC_DECODE == 1\n");
    body.push_str("                fprintf(g6lc_tensor_file,\n");
    body.push_str("                    \",\\\"flags_layout\\\":{\\\"dtype_shift\\\":%u,\\\"dtype_mask\\\":%u,\\\"priority_shift\\\":%u,\\\"priority_mask\\\":%u,\\\"irq_bit\\\":%u}\",\n");
    body.push_str("                    G6LC_AI_DTYPE_SHIFT, G6LC_AI_DTYPE_MASK,\n");
    body.push_str("                    G6LC_AI_PRIO_SHIFT, G6LC_AI_PRIO_MASK, G6LC_AI_IRQ_BIT);\n");
    body.push_str("#endif\n");
    body.push_str("                fprintf(g6lc_tensor_file, \",\\\"events\\\":[\\n\");\n");
    body.push_str("            }\n");
    body.push_str("        }\n");
    body.push_str("#endif\n");
    body.push_str("    }\n");
    body.push_str("    if (g6lc_trace_insns == NULL) {\n");
    body.push_str("        g6lc_trace_insns = g_ptr_array_new();\n");
    body.push_str("        g_ptr_array_set_free_func(g6lc_trace_insns, g_free);\n");
    body.push_str("    }\n");
    body.push_str("#if G6LC_AI_DESC_DECODE == 1\n");
    body.push_str("    for (uint32_t h = 0; h < G6LC_HARTS_TOTAL; ++h) {\n");
    body.push_str("        g6lc_tensor_events[h] = NULL;\n");
    body.push_str("        g6lc_next_ticket[h] = 0;\n");
    body.push_str("    }\n");
    body.push_str("#endif\n\n");
    body.push_str("    qemu_plugin_register_vcpu_init_cb(id, g6lc_vcpu_init);\n");
    body.push_str("    qemu_plugin_register_vcpu_idle_cb(id, g6lc_vcpu_idle);\n");
    body.push_str("    qemu_plugin_register_vcpu_resume_cb(id, g6lc_vcpu_resume);\n");
    body.push_str("    qemu_plugin_register_vcpu_exit_cb(id, g6lc_vcpu_exit);\n");
    body.push_str("    qemu_plugin_register_vcpu_tb_trans_cb(id, g6lc_tb_trans);\n");
    body.push_str("    qemu_plugin_register_atexit_cb(id, g6lc_atexit, NULL);\n");
    body.push_str("    return 0;\n");
    body.push_str("}\n");

    let mut emission = Emission::new();
    emission.push(EmittedFile::new(
        format!("contrib/plugins/g6lc-{name}.c"),
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
    fn emitted_plugin_has_gpl_header_and_callbacks() {
        let m = TargetModel::new("g6lc64_test");
        let e = emit_plugin(&m, "0.1.0", "sha256:abc");
        assert_eq!(e.files.len(), 1);
        let f = &e.files[0];
        assert!(f.header_is_valid());
        assert!(f.contents.contains("QEMU_PLUGIN_VERSION"));
        assert!(f.contents.contains("qemu_plugin_install"));
        assert!(f.contents.contains("qemu_plugin_register_vcpu_tb_trans_cb"));
        assert!(f.contents.contains("qemu_plugin_register_vcpu_init_cb"));
        assert!(f.contents.contains("qemu_plugin_register_vcpu_idle_cb"));
        assert!(f.contents.contains("qemu_plugin_register_vcpu_resume_cb"));
        assert!(f.contents.contains("qemu_plugin_register_vcpu_exit_cb"));
        assert!(f.contents.contains("qemu_plugin_register_atexit_cb"));
        assert!(f
            .contents
            .contains("qemu_plugin_register_vcpu_insn_exec_cb"));
        assert!(f.contents.contains("qemu_plugin_register_vcpu_mem_cb"));
        assert!(f.contents.contains("g6lc_vcpu_init"));
        assert!(f.contents.contains("g6lc_vcpu_idle"));
        assert!(f.contents.contains("g6lc_vcpu_resume"));
        assert!(f.contents.contains("qemu_plugin_mem_is_store"));
        assert!(f.contents.contains("qemu_plugin_mem_size_shift"));
        assert!(f.contents.contains("qemu_plugin_get_hwaddr"));
        assert!(f.contents.contains("qemu_plugin_hwaddr_is_io"));
        assert!(f.contents.contains("g6lc_mmio_count"));
        assert!(f.contents.contains("G6LC_TARGET_ID"));
        assert!(f.contents.contains("G6LC_PROFILE"));
        assert!(f.contents.contains("G6LC_PROFILE_TAINTED"));
        assert!(f.contents.contains("g6lc_tensor_file"));
        assert!(f.contents.contains("g6lc_tensor_write"));
        assert!(f.contents.contains("tensor="));
    }

    /// A model that resolves the descriptor geometry, mirroring the reference package:
    /// packed field offsets, and a latch window the island places at a stated base.
    fn model_with_island() -> TargetModel {
        use g6q_core::model::{
            AiDescLayout, AiIslandConfig, AiIslandModel, DescField, DescFlagsLayout, Peripheral,
        };
        let mut m = TargetModel::new("g6lc64_ai");
        m.soc.harts_total = 2;
        m.soc.peripherals.push(Peripheral {
            id: "ai-island".into(),
            base: 0x4000_0000,
            len: 0x1000,
            ..Default::default()
        });
        let mut fields = std::collections::BTreeMap::new();
        for (name, offset, size) in [
            ("version", 0u64, 2u64),
            ("op", 2, 2),
            ("flags", 4, 4),
            ("m", 8, 4),
            ("n", 12, 4),
            ("k", 16, 4),
            ("ld_ab", 20, 4),
            ("ptr_a", 24, 8),
            ("ptr_b", 32, 8),
            ("ptr_c", 40, 8),
            ("ptr_scale", 48, 8),
            ("ptr_done", 56, 8),
        ] {
            fields.insert(
                name.to_string(),
                DescField {
                    offset,
                    size,
                    bit_low: offset * 8,
                    bit_high: (offset + size) * 8 - 1,
                },
            );
        }
        m.soc.ai_island = Some(AiIslandModel {
            instr_set: g6q_core::model::AiInstrSet {
                opcode_custom2: 0x5B,
                mask_f7f3op: 0xFE00_707F,
                match_enq: 0x0000_505B,
                match_poll: 0x0200_505B,
                match_qfence: 0x0400_505B,
                csr_aiqbase: 0,
                csr_aiqctl: 0,
                csr_aiqhead: 0,
            },
            config: AiIslandConfig {
                queues: 2,
                queue_depth: 8,
                cap_base: Some(0),
                desc_base: Some(0x140),
                ..Default::default()
            },
            desc_layout: AiDescLayout {
                desc_bytes: 64,
                version: Some(1),
                fields,
                ops: std::collections::BTreeMap::new(),
                statuses: [("ST_OK".into(), 0)].into_iter().collect(),
                completion: Some(g6q_core::model::CompletionLayout {
                    ticket_bit_low: 0,
                    ticket_bit_high: 31,
                    status_bit_low: 32,
                    status_bit_high: 47,
                }),
                flags_layout: Some(DescFlagsLayout {
                    dtype_shift: 8,
                    dtype_mask: 0x3f,
                    priority_shift: 16,
                    priority_mask: 0x0f,
                    irq_bit: 2,
                    dtype_combined: true,
                    ..Default::default()
                }),
            },
        });
        m
    }

    #[test]
    fn descriptor_decode_is_off_when_the_geometry_is_unresolved() {
        // No island at all.
        let m = TargetModel::new("g6lc64_test");
        let e = emit_plugin(&m, "0.1.0", "sha256:abc");
        assert!(e.files[0]
            .contents
            .contains("#define G6LC_AI_DESC_DECODE 0"));
        assert!(!e.files[0].contents.contains("g6lc_desc_submit"));

        // An island whose placement the design does not publish must not be decoded
        // either: a guessed base relocates the whole descriptor.
        let mut m = model_with_island();
        if let Some(ai) = m.soc.ai_island.as_mut() {
            ai.config.desc_base = None;
        }
        let e = emit_plugin(&m, "0.1.0", "sha256:abc");
        assert!(e.files[0]
            .contents
            .contains("#define G6LC_AI_DESC_DECODE 0"));
        assert!(!e.files[0].contents.contains("g6lc_desc_submit"));
    }

    #[test]
    fn an_unreachable_gpr_is_reported_rather_than_silently_dropping_events() {
        let m = model_with_island();
        let e = emit_plugin(&m, "0.1.0", "sha256:abc");
        let c = &e.files[0].contents;
        assert!(c.contains("g6lc_warn_no_gpr"));
        assert!(
            c.contains("qemu_plugin_get_registers() on this"),
            "the warning must name the API that cannot answer"
        );
        // The register list grows, so a lookup miss must re-fetch rather than be cached.
        assert!(c.contains("fresh = qemu_plugin_get_registers();"));
        assert!(c.contains("g6lc_find_xreg(g6lc_regs[vcpu_index], idx, out)"));
    }

    #[test]
    fn descriptor_offsets_in_the_plugin_come_from_the_layout() {
        let e = emit_plugin(&model_with_island(), "0.1.0", "sha256:abc");
        let c = &e.files[0].contents;
        assert!(c.contains("#define G6LC_AI_DESC_DECODE 1"));
        assert!(c.contains("#define G6LC_AI_DESC_BASE 0x140ULL"));
        assert!(c.contains("#define G6LC_AI_DESC_BYTES 64"));
        // ptr_done at 56 comes from the layout, not from a stride invented here.
        assert!(c.contains("#define G6LC_AI_OFF_PTR_DONE 56"));
        assert!(c.contains("#define G6LC_AI_SZ_PTR_DONE 8"));
        assert!(c.contains("#define G6LC_AI_OFF_LD_AB 20"));
        // Status code for completion comes from the layout, not a literal.
        assert!(c.contains("#define G6LC_AI_ST_OK 0U"));
        // No literal stride from the old hand-written surface.
        assert!(!c.contains("G6LC_AI_OFF_PTR_DONE 0x40"));
    }

    #[test]
    fn the_plugin_reads_store_values_and_emits_submissions() {
        let e = emit_plugin(&model_with_island(), "0.1.0", "sha256:abc");
        let c = &e.files[0].contents;
        // Reassembly needs the stored value, which the pinned plugin API provides.
        assert!(c.contains("qemu_plugin_mem_get_value"));
        assert!(c.contains("QEMU_PLUGIN_MEM_VALUE_U64"));
        assert!(c.contains("g6lc_desc_shadow"));
        assert!(c.contains("g6lc_desc_store"));
        assert!(c.contains("g6lc_desc_submit"));
        // The latch path reports a window-relative offset; the instruction path reports a
        // guest-physical address. Conflating them put a DRAM descriptor at a bogus offset.
        assert!(c.contains("paddr - G6LC_AI_ISLAND_BASE"));
        assert!(c.contains("g6lc_desc_submit_at(vcpu_index, desc_addr)"));
        // The dtype packing is emitted from the ingested flags layout.
        let flags = model_with_island()
            .soc
            .ai_island
            .as_ref()
            .unwrap()
            .desc_layout
            .flags_layout
            .unwrap();
        assert!(c.contains(&format!(
            "#define G6LC_AI_DTYPE_SHIFT {}",
            flags.dtype_shift
        )));
        assert!(c.contains(&format!(
            "#define G6LC_AI_DTYPE_MASK 0x{:x}U",
            flags.dtype_mask
        )));
    }

    #[test]
    fn the_queue_instruction_path_uses_the_ingested_encoding() {
        let e = emit_plugin(&model_with_island(), "0.1.0", "sha256:abc");
        let c = &e.files[0].contents;
        assert!(c.contains("#define G6LC_AI_ENQ_DECODE 1"));
        // Mask and match come from the model's instruction set, not from a literal here.
        assert!(c.contains("#define G6LC_AI_ENQ_MASK 0xfe00707fU"));
        assert!(c.contains("#define G6LC_AI_ENQ_MATCH 0x0000505bU"));
        assert!(c.contains("(info->data & G6LC_AI_ENQ_MASK) == G6LC_AI_ENQ_MATCH"));
        // Reading a register requires the callback to ask for register access.
        assert!(c.contains("QEMU_PLUGIN_CB_R_REGS"));
        assert!(c.contains("qemu_plugin_read_register"));
        assert!(c.contains("qemu_plugin_get_registers"));
        // The descriptor is read from guest memory, not from the MMIO window.
        assert!(c.contains("qemu_plugin_read_memory_vaddr"));
        assert!(c.contains("g6lc_ai_enq_exec"));
    }

    #[test]
    fn the_queue_path_is_absent_without_an_ingested_encoding() {
        // A zero mask would match every instruction, so an un-ingested instruction set
        // must disable the path rather than default it.
        let mut m = model_with_island();
        if let Some(ai) = m.soc.ai_island.as_mut() {
            ai.instr_set = Default::default();
        }
        let e = emit_plugin(&m, "0.1.0", "sha256:abc");
        let c = &e.files[0].contents;
        assert!(c.contains("#define G6LC_AI_ENQ_DECODE 0"));
        assert!(!c.contains("g6lc_ai_enq_exec"));
        assert!(!c.contains("qemu_plugin_read_memory_vaddr"));

        // It also stays off when the descriptor geometry is unresolved: without a size
        // there is nothing to read from guest memory.
        let mut m = model_with_island();
        if let Some(ai) = m.soc.ai_island.as_mut() {
            ai.config.desc_base = None;
        }
        let e = emit_plugin(&m, "0.1.0", "sha256:abc");
        assert!(e.files[0].contents.contains("#define G6LC_AI_ENQ_DECODE 0"));
        assert!(!e.files[0].contents.contains("g6lc_ai_enq_exec"));
    }

    /// The whole point of the artifact contract: a consumer must not be able to tell
    /// which backend produced an event. Every key the native artifact renders has to
    /// appear in the emitted plugin's submission record.
    #[test]
    fn the_submission_record_matches_the_native_artifact_shape() {
        let e = emit_plugin(&model_with_island(), "0.1.0", "sha256:abc");
        let c = &e.files[0].contents;
        for key in [
            "order",
            "hart",
            "descriptor_addr",
            "op",
            "version",
            "flags",
            "m",
            "n",
            "k",
            "ld_ab",
            "ptr_a",
            "ptr_b",
            "ptr_c",
            "ptr_scale",
            "ptr_done",
            "dtype",
            "cluster",
            "ticket",
            "status",
            "done",
            "pmu_r_beats",
            "pmu_w_beats",
            "pmu_cycles",
            "pmu_gbps_x1000",
        ] {
            assert!(
                c.contains(&format!("\\\"{key}\\\"")),
                "emitted plugin is missing artifact key {key:?}"
            );
        }
        assert!(
            c.contains("\\\"done\\\":%s"),
            "done must be emitted as a JSON string"
        );
        assert!(c.contains("e->done ? \"true\" : \"false\""));
        assert!(
            c.contains("e->pmu_r_beats, e->pmu_w_beats, e->pmu_cycles, e->pmu_gbps_x1000"),
            "PMU fields must be passed to fprintf"
        );
        for pmu in ["pmu_r_beats", "pmu_w_beats", "pmu_cycles", "pmu_gbps_x1000"] {
            assert!(
                c.contains(&format!("ev.{pmu} = 0")),
                "PMU field {pmu:?} must be zeroed at submission"
            );
        }
        assert!(!c.contains("\\\"done\\\":false"));
        assert!(c.contains("g6lc_tensor_event_write"));
        assert!(c.contains("g6lc_tensor_complete_by_ptr_done"));
        assert!(c.contains("g6lc_next_ticket[h] = 0"));
        assert!(c.contains("ev.ticket = g6lc_next_ticket[hart]"));
        assert!(c.contains("g6lc_tensor_events[h] = NULL"));
        assert!(c.contains("g_array_free(g6lc_tensor_events[h], TRUE)"));
        assert!(c.contains("G6LC_PROFILE"));
        assert!(c.contains("G6LC_PROFILE_TAINTED"));
        assert!(c.contains("\\\"profile_tainted\\\":%s"));
        assert!(c.contains("G6LC_AI_ST_OK"));
        assert!(c.contains("e->status = G6LC_AI_ST_OK"));
    }

    #[test]
    fn cluster_dispatch_uses_queue_cluster_map_when_descriptor_lacks_cluster() {
        let mut m = model_with_island();
        if let Some(ai) = m.soc.ai_island.as_mut() {
            ai.config.queue_cluster_map = Some(vec![0, 1]);
        }
        let e = emit_plugin(&m, "0.1.0", "sha256:abc");
        let c = &e.files[0].contents;
        // The plugin emits the map and a fallback in g6lc_desc_submit.
        assert!(c.contains("#define G6LC_AI_QUEUES 2"));
        assert!(c.contains("#define G6LC_AI_QUEUE_CLUSTER_MAP_LEN 2"));
        assert!(c.contains("static const uint32_t g6lc_queue_cluster_map[2] = { 0, 1 }"));
        assert!(c.contains("if (ev.cluster == 0 && G6LC_AI_QUEUE_CLUSTER_MAP_LEN > 0)"));
        assert!(c.contains("g6lc_queue_cluster_map[hart % G6LC_AI_QUEUES]"));
    }

    #[test]
    fn the_qfence_instruction_path_uses_the_ingested_encoding() {
        let e = emit_plugin(&model_with_island(), "0.1.0", "sha256:abc");
        let c = &e.files[0].contents;
        assert!(c.contains("#define G6LC_AI_QFENCE_DECODE 1"));
        // Mask and match come from the model's instruction set, not from a literal here.
        assert!(c.contains("#define G6LC_AI_QFENCE_MASK 0xfe00707fU"));
        assert!(c.contains("#define G6LC_AI_QFENCE_MATCH 0x0400505bU"));
        assert!(c.contains("(info->data & G6LC_AI_QFENCE_MASK) == G6LC_AI_QFENCE_MATCH"));
        // Queue fences do not need register access.
        assert!(c.contains("QEMU_PLUGIN_CB_NO_REGS"));
        assert!(c.contains("g6lc_ai_qfence_exec"));
    }

    #[test]
    fn the_qfence_path_is_absent_without_an_ingested_encoding() {
        let mut m = model_with_island();
        if let Some(ai) = m.soc.ai_island.as_mut() {
            ai.instr_set = Default::default();
        }
        let e = emit_plugin(&m, "0.1.0", "sha256:abc");
        let c = &e.files[0].contents;
        assert!(c.contains("#define G6LC_AI_QFENCE_DECODE 0"));
        assert!(!c.contains("g6lc_ai_qfence_exec"));
    }

    #[test]
    fn the_poll_instruction_path_uses_the_ingested_encoding() {
        let e = emit_plugin(&model_with_island(), "0.1.0", "sha256:abc");
        let c = &e.files[0].contents;
        assert!(c.contains("#define G6LC_AI_POLL_DECODE 1"));
        // Mask and match come from the model's instruction set, not from a literal here.
        assert!(c.contains("#define G6LC_AI_POLL_MASK 0xfe00707fU"));
        assert!(c.contains("#define G6LC_AI_POLL_MATCH 0x0200505bU"));
        assert!(c.contains("(info->data & G6LC_AI_POLL_MASK) == G6LC_AI_POLL_MATCH"));
        // Poll needs the ticket from rs1 and reads the completion word.
        assert!(c.contains("QEMU_PLUGIN_CB_R_REGS"));
        assert!(c.contains("g6lc_ai_poll_exec"));
        assert!(c.contains("qemu_plugin_read_memory_vaddr"));
        // Completion bit ranges come from the ingested make_completion layout.
        assert!(c.contains("G6LC_AI_COMPLETION_TICKET_BIT_LOW"));
        assert!(c.contains("G6LC_AI_COMPLETION_STATUS_BIT_HIGH"));
    }

    #[test]
    fn the_poll_path_is_absent_without_completion_layout() {
        // The ai.poll path cannot decode the completion word unless the package publishes
        // the layout through make_completion.
        let mut m = model_with_island();
        if let Some(ai) = m.soc.ai_island.as_mut() {
            ai.desc_layout.completion = None;
        }
        let e = emit_plugin(&m, "0.1.0", "sha256:abc");
        let c = &e.files[0].contents;
        assert!(c.contains("#define G6LC_AI_POLL_DECODE 0"));
        assert!(!c.contains("g6lc_ai_poll_exec"));
    }

    #[test]
    fn the_ptr_done_completion_path_decodes_when_layout_resolved() {
        let e = emit_plugin(&model_with_island(), "0.1.0", "sha256:abc");
        let c = &e.files[0].contents;
        assert!(c.contains("#define G6LC_AI_COMPLETION_DECODE 1"));
        assert!(c.contains("g6lc_tensor_complete_by_ptr_done(vcpu_index, paddr, store_word)"));
        // The store-value path extracts a 64-bit word from the QEMU mem_value.
        assert!(c.contains("qemu_plugin_mem_value val = qemu_plugin_mem_get_value(meminfo)"));
        assert!(c.contains("case QEMU_PLUGIN_MEM_VALUE_U64: store_word = val.data.u64; break;"));
        // It decodes ticket and status from the word using the ingested layout.
        assert!(c.contains("G6LC_AI_COMPLETION_TICKET_BIT_LOW"));
        assert!(c.contains("G6LC_AI_COMPLETION_STATUS_BIT_HIGH"));
        assert!(c.contains("if (read_ticket == e->ticket && read_status == G6LC_AI_ST_OK)"));
    }

    #[test]
    fn the_ptr_done_completion_path_falls_back_without_layout() {
        let mut m = model_with_island();
        if let Some(ai) = m.soc.ai_island.as_mut() {
            ai.desc_layout.completion = None;
        }
        let e = emit_plugin(&m, "0.1.0", "sha256:abc");
        let c = &e.files[0].contents;
        assert!(!c.contains("#define G6LC_AI_COMPLETION_DECODE"));
        assert!(c.contains("g6lc_tensor_complete_by_ptr_done(vcpu_index, paddr, store_word)"));
        assert!(c.contains("#else\n        e->done = true;"));
    }
}
