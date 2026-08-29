// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! B1 AI-island sysbus device and helper-target state.
//!
//! This module emits the generated `hw/riscv/g6lc-<target>-ai-island.{h,c}` files. The
//! device owns the queue state and the helpers in
//! `target/riscv/g6lc-<target>-ai-helpers.c` call into it.
//!
//! Everything guest-visible here is emitted from the ingested model: the completion-word
//! bit layout comes from the descriptor package's `make_completion`, the status codes from
//! its `ST_*` constants, the accepted descriptor version from its published version
//! constant, and the capability window from `CAP_OFF_*` plus the cap window's packed-word
//! layout. That matters more here than anywhere else in the crate, because the native VM
//! (`g6q-vm`) and the TCG plugin already answer the same ABI: a literal in this file would
//! make the *emulator* the source of a mismatch that then gets blamed on the RTL.

use crate::{Emission, EmittedFile};
use g6q_core::model::{AiIslandModel, TargetModel};

/// The `ai.poll` "not finished yet" sentinel.
///
/// The descriptor package does not publish a pending encoding — it publishes completion
/// *statuses*, which only exist once an entry is done. This value is therefore an emulator
/// convention shared with the native VM (`g6q-vm::AiIsland::queue_poll`) and is named once
/// so the two backends cannot drift; recorded as an ask in `architecture/RTL_FEEDBACK.md`.
pub const POLL_PENDING: u64 = 0xffff_ffff;

/// Descriptor geometry and instruction encoding both resolved, i.e. the device can be
/// emitted without inventing a guest-visible number.
///
/// The check is shared with [`crate::trans`] so the device and the helpers that call into
/// it are always emitted as a pair. Emitting one half produced either a device with no
/// callers or helpers referencing a missing header.
pub fn resolved(model: &TargetModel) -> Option<(String, &AiIslandModel)> {
    let island = model.soc.ai_island.as_ref()?;
    let instr = &island.instr_set;
    if instr.mask_f7f3op == 0 || instr.opcode_custom2 == 0 {
        return None;
    }
    // The descriptor size and the completion pointer's offset are the two numbers the
    // device cannot do without. Absence is reported by emitting nothing, per the same rule
    // the B2 plugin follows: decoding against a guessed geometry produces
    // plausible-looking wrong events, which is worse than no events.
    if island.desc_layout.desc_bytes == 0 || island.desc_layout.offset("ptr_done").is_none() {
        return None;
    }
    Some((crate::machine::machine_name(&model.target_id), island))
}

/// Emit `hw/riscv/g6lc-<target>-ai-island.h`.
pub fn emit_island_h(model: &TargetModel, version: &str, digest: &str) -> Option<EmittedFile> {
    let (safe_id, island) = resolved(model)?;
    let config = &island.config;
    let layout = &island.desc_layout;

    let queues = config.queues.max(1);
    let depth = config.queue_depth.max(1);
    let desc_bytes = layout.desc_bytes;
    let ptr_done_off = layout.offset("ptr_done")?;

    // The completion word is packed by the IR, so the emitted macro is a table lookup over
    // two precomputed constants rather than a re-implementation of the bit layout.
    let ticket_word = layout.pack_completion_word(!0u64, 0);
    let status_word = layout.pack_completion_word(0, !0u64);
    let ticket_shift = ticket_word.trailing_zeros();
    let status_shift = if status_word == 0 {
        0
    } else {
        status_word.trailing_zeros()
    };
    let ticket_mask = ticket_word >> ticket_shift;
    let status_mask = status_word >> status_shift;

    let st_ok = layout.status("ST_OK");
    let st_bad_ver = layout.status("ST_BAD_VER");

    let mut body = format!(
        r###"
/*
 * Generated AI-island device state for the {id} machine.
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef G6LC_{upper}_AI_ISLAND_H
#define G6LC_{upper}_AI_ISLAND_H

#include "exec/memory.h"

#define G6LC_AI_ISLAND_QUEUES {queues}
#define G6LC_AI_ISLAND_QUEUE_DEPTH {depth}
#define G6LC_AI_ISLAND_DESC_BYTES {desc_bytes}
#define G6LC_AI_ISLAND_PTR_DONE_OFF {ptr_done_off}

/*
 * Completion word layout, from the descriptor package's own make_completion():
 * ticket occupies mask 0x{ticket_mask:x} at bit {ticket_shift}, status mask 0x{status_mask:x}
 * at bit {status_shift}. Do not re-derive these; they are packed by the generator.
 */
#define G6LC_AI_TICKET_MASK  0x{ticket_mask:x}ULL
#define G6LC_AI_TICKET_SHIFT {ticket_shift}
#define G6LC_AI_STATUS_MASK  0x{status_mask:x}ULL
#define G6LC_AI_STATUS_SHIFT {status_shift}
#define G6LC_AI_COMPLETION(ticket, status) \
    ((((uint64_t)(ticket) & G6LC_AI_TICKET_MASK) << G6LC_AI_TICKET_SHIFT) | \
     (((uint64_t)(status) & G6LC_AI_STATUS_MASK) << G6LC_AI_STATUS_SHIFT))

/* `ai.poll` pending sentinel, shared with the native VM. */
#define G6LC_AI_POLL_PENDING 0x{poll_pending:x}ULL
"###,
        id = safe_id,
        upper = safe_id.to_uppercase(),
        queues = queues,
        depth = depth,
        desc_bytes = desc_bytes,
        ptr_done_off = ptr_done_off,
        ticket_mask = ticket_mask,
        ticket_shift = ticket_shift,
        status_mask = status_mask,
        status_shift = status_shift,
        poll_pending = POLL_PENDING,
    );

    // Status codes are emitted only when the package names them. A device that reported a
    // guessed status would make a completion word look valid to a driver that checks it.
    if let Some(v) = st_ok {
        body.push_str(&format!("#define G6LC_AI_ST_OK {v}\n"));
    }
    if let Some(v) = st_bad_ver {
        body.push_str(&format!("#define G6LC_AI_ST_BAD_VER {v}\n"));
    }
    if let Some(v) = layout.version {
        body.push_str(&format!("#define G6LC_AI_DESC_VERSION {v}\n"));
        if let Some(off) = layout.offset("version") {
            body.push_str(&format!("#define G6LC_AI_OFF_VERSION {off}\n"));
        }
    }

    body.push_str(&format!(
        r###"
typedef struct G6lcAIQueueEntry {{
    uint64_t desc_addr;
    uint64_t ptr_done;
    uint64_t ticket;
    uint64_t status;
    bool done;
    bool used;
}} G6lcAIQueueEntry;

typedef struct G6lcAIIsland {{
    MemoryRegion mmio;
    bool cap_decoded;
    uint64_t cap_base;
    bool desc_decoded;
    uint64_t desc_base;
    G6lcAIQueueEntry queues[G6LC_AI_ISLAND_QUEUES][G6LC_AI_ISLAND_QUEUE_DEPTH];
    uint64_t next_ticket;
    unsigned int head[G6LC_AI_ISLAND_QUEUES];
    unsigned int tail[G6LC_AI_ISLAND_QUEUES];
}} G6lcAIIsland;

extern G6lcAIIsland *g6lc_ai_island;

G6lcAIIsland *g6lc_ai_island_create(hwaddr base, hwaddr size,
                                    bool cap_decoded, uint64_t cap_base,
                                    bool desc_decoded, uint64_t desc_base);
uint64_t g6lc_ai_island_enq(G6lcAIIsland *island, CPURISCVState *env,
                            uint64_t desc_ptr);
void g6lc_ai_island_qfence(G6lcAIIsland *island, CPURISCVState *env);
uint64_t g6lc_ai_island_poll(G6lcAIIsland *island, CPURISCVState *env,
                             uint64_t ticket);

#endif /* G6LC_{upper}_AI_ISLAND_H */
"###,
        upper = safe_id.to_uppercase(),
    ));

    Some(EmittedFile::new(
        format!("hw/riscv/g6lc-{safe_id}-ai-island.h"),
        version,
        digest,
        &body,
    ))
}

/// Emit `hw/riscv/g6lc-<target>-ai-island.c`.
pub fn emit_island_c(model: &TargetModel, version: &str, digest: &str) -> Option<EmittedFile> {
    let (safe_id, island) = resolved(model)?;
    let layout = &island.desc_layout;

    // The whole capability window, sourced by the IR, so the generated device answers the
    // same offsets the native VM answers. An offset the model never named is absent from
    // the table and reads back as "no such word" rather than as zero.
    let cap_words = island.config.cap_words();
    // An empty window emits no table and no lookup: a zero-length array is not valid C,
    // and a lookup with nothing to find would report every offset as the legal value zero.
    let (cap_table, cap_lookup) = if cap_words.is_empty() {
        (
            String::new(),
            "    /* The model names no capability word this generator can source. */\n\
             \x20   (void)s;\n\
             \x20   return 0;\n"
                .to_string(),
        )
    } else {
        let rows: Vec<String> = cap_words
            .iter()
            .map(|(off, val)| format!("    {{ {off}, 0x{val:x}ULL }},"))
            .collect();
        (
            format!(
                "typedef struct G6lcAICapWord {{\n\
                 \x20   uint64_t offset;\n\
                 \x20   uint64_t value;\n\
                 }} G6lcAICapWord;\n\
                 \n\
                 /* Capability window, from the design's CAP_OFF_* offsets and packed-word layout. */\n\
                 static const G6lcAICapWord g6lc_ai_cap_words[] = {{\n{rows}\n}};\n\n",
                rows = rows.join("\n")
            ),
            "    size_t i;\n\
             \n\
             \x20   if (!s->cap_decoded || offset < s->cap_base) {\n\
             \x20       return 0;\n\
             \x20   }\n\
             \x20   for (i = 0; i < ARRAY_SIZE(g6lc_ai_cap_words); i++) {\n\
             \x20       if (g6lc_ai_cap_words[i].offset == offset - s->cap_base) {\n\
             \x20           return g6lc_ai_cap_words[i].value;\n\
             \x20       }\n\
             \x20   }\n\
             \x20   return 0;\n"
                .to_string(),
        )
    };

    // A version check only exists when the package publishes both the accepted version and
    // the field it lives in, plus a code to report a mismatch with.
    let version_check = match (
        layout.version,
        layout.offset("version"),
        layout.status("ST_BAD_VER"),
    ) {
        (Some(_), Some(_), Some(_)) => {
            "    if (cpu_lduw_data(env, desc_ptr + G6LC_AI_OFF_VERSION) !=\n\
             \x20       G6LC_AI_DESC_VERSION) {\n\
             \x20       return G6LC_AI_COMPLETION(0, G6LC_AI_ST_BAD_VER);\n\
             \x20   }\n"
        }
        // Unresolved: no check is emitted, rather than a check against a guessed version
        // that would reject every descriptor the design actually accepts.
        _ => "",
    };

    let ok_status = if layout.status("ST_OK").is_some() {
        "G6LC_AI_ST_OK"
    } else {
        // No ST_OK published: the entry carries whatever status it was completed with,
        // which for this device is zero-initialised state, not an asserted "OK".
        "0"
    };

    let body = format!(
        r###"
/*
 * Generated AI-island device for the {id} machine.
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "cpu.h"
#include "exec/address-spaces.h"
#include "exec/cpu-all.h"
#include "exec/cpu_ldst.h"
#include "exec/memory.h"
#include "g6lc-{id}-ai-island.h"

G6lcAIIsland *g6lc_ai_island = NULL;

{cap_table}static uint64_t g6lc_{id}_ai_island_read(void *opaque, hwaddr offset,
                                         unsigned int size)
{{
    G6lcAIIsland *s = (G6lcAIIsland *)opaque;

    (void)size;
{cap_lookup}}}

static void g6lc_{id}_ai_island_write(void *opaque, hwaddr offset,
                                       uint64_t val, unsigned int size)
{{
    /*
     * The descriptor latch window is observed by the B2 plugin, which reassembles
     * descriptors from store values. The helper path submits by pointer, so this
     * device has no latch state to keep.
     */
    (void)opaque;
    (void)offset;
    (void)val;
    (void)size;
}}

static const MemoryRegionOps g6lc_{id}_ai_island_ops = {{
    .read = g6lc_{id}_ai_island_read,
    .write = g6lc_{id}_ai_island_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl.min_access_size = 1,
    .impl.max_access_size = 8,
    .valid.min_access_size = 1,
    .valid.max_access_size = 8,
}};

G6lcAIIsland *g6lc_ai_island_create(hwaddr base, hwaddr size,
                                    bool cap_decoded, uint64_t cap_base,
                                    bool desc_decoded, uint64_t desc_base)
{{
    G6lcAIIsland *s = g_new0(G6lcAIIsland, 1);

    s->cap_decoded = cap_decoded;
    s->cap_base = cap_base;
    s->desc_decoded = desc_decoded;
    s->desc_base = desc_base;
    if (!cap_decoded) {{
        /*
         * The design does not publish the capability window's base, so the window is
         * left undecoded rather than placed at a guessed address: a wrong base makes
         * every individual capability look correctly placed relative to its neighbours.
         */
        warn_report("g6lc-{id}: AI-island capability window base unresolved; "
                    "capability reads return 0");
    }}
    memory_region_init_io(&s->mmio, NULL, &g6lc_{id}_ai_island_ops, s,
                          "g6lc-{id}-ai-island-mmio", size);
    memory_region_add_subregion(get_system_memory(), base, &s->mmio);
    g6lc_ai_island = s;
    return s;
}}

uint64_t g6lc_ai_island_enq(G6lcAIIsland *island, CPURISCVState *env,
                            uint64_t desc_ptr)
{{
    unsigned int q, slot;
    uint64_t ticket, ptr_done;
    G6lcAIQueueEntry *e;

    if (!island) {{
        return 0;
    }}
    /* One ring per hart, wrapping when there are fewer rings than harts. */
    q = env_cpu(env)->cpu_index % G6LC_AI_ISLAND_QUEUES;
    slot = island->tail[q] % G6LC_AI_ISLAND_QUEUE_DEPTH;
    if (island->queues[q][slot].used) {{
        /* Ring full. Zero, not the pending sentinel, so a caller can tell them apart. */
        return 0;
    }}
{version_check}    ptr_done = cpu_ldq_data(env, desc_ptr + G6LC_AI_ISLAND_PTR_DONE_OFF);
    /* Island-wide ticket allocation, so a ticket is unambiguous across rings. */
    ticket = island->next_ticket++;
    e = &island->queues[q][slot];
    e->desc_addr = desc_ptr;
    e->ptr_done = ptr_done;
    e->ticket = ticket;
    e->status = {ok_status};
    e->done = false;
    e->used = true;
    island->tail[q] = (slot + 1) % G6LC_AI_ISLAND_QUEUE_DEPTH;
    return ticket;
}}

static void g6lc_ai_island_complete_entry(G6lcAIQueueEntry *e,
                                          CPURISCVState *env)
{{
    if (e->done) {{
        return;
    }}
    e->done = true;
    e->status = {ok_status};
    if (e->ptr_done) {{
        cpu_stq_data(env, e->ptr_done,
                     G6LC_AI_COMPLETION(e->ticket, e->status));
    }}
}}

void g6lc_ai_island_qfence(G6lcAIIsland *island, CPURISCVState *env)
{{
    unsigned int q, slot;

    if (!island) {{
        return;
    }}
    for (q = 0; q < G6LC_AI_ISLAND_QUEUES; ++q) {{
        for (slot = 0; slot < G6LC_AI_ISLAND_QUEUE_DEPTH; ++slot) {{
            G6lcAIQueueEntry *e = &island->queues[q][slot];
            if (e->used) {{
                g6lc_ai_island_complete_entry(e, env);
            }}
        }}
    }}
}}

uint64_t g6lc_ai_island_poll(G6lcAIIsland *island, CPURISCVState *env,
                             uint64_t ticket)
{{
    unsigned int q, slot;

    if (!island) {{
        return 0;
    }}
    for (q = 0; q < G6LC_AI_ISLAND_QUEUES; ++q) {{
        for (slot = 0; slot < G6LC_AI_ISLAND_QUEUE_DEPTH; ++slot) {{
            G6lcAIQueueEntry *e = &island->queues[q][slot];
            if (!e->used || e->ticket != ticket) {{
                continue;
            }}
            if (!e->done) {{
                return G6LC_AI_POLL_PENDING;
            }}
            /* Completed: publish the word and retire the entry. */
            if (e->ptr_done) {{
                cpu_stq_data(env, e->ptr_done,
                             G6LC_AI_COMPLETION(e->ticket, e->status));
            }}
            e->used = false;
            return G6LC_AI_COMPLETION(e->ticket, e->status);
        }}
    }}
    /* Unknown or already-retired ticket: the work is not outstanding. */
    return G6LC_AI_COMPLETION(ticket, {ok_status});
}}
"###,
        id = safe_id,
        cap_table = cap_table,
        cap_lookup = cap_lookup,
        version_check = version_check,
        ok_status = ok_status,
    );

    Some(EmittedFile::new(
        format!("hw/riscv/g6lc-{safe_id}-ai-island.c"),
        version,
        digest,
        &body,
    ))
}

/// Add the AI-island device files to an emission.
pub fn emit(model: &TargetModel, version: &str, digest: &str, emission: &mut Emission) {
    if let Some(f) = emit_island_h(model, version, digest) {
        emission.push(f);
    }
    if let Some(f) = emit_island_c(model, version, digest) {
        emission.push(f);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use g6q_core::model::{
        AiDescLayout, AiInstrSet, AiIslandConfig, CapBlockMnk, CapPackedField, CompletionLayout,
        DescField,
    };

    fn field(offset: u64, size: u64) -> DescField {
        DescField {
            offset,
            size,
            bit_low: 0,
            bit_high: 0,
        }
    }

    fn island_model() -> TargetModel {
        let mut layout = AiDescLayout {
            desc_bytes: 64,
            version: Some(1),
            ..Default::default()
        };
        layout.fields.insert("version".into(), field(0, 2));
        layout.fields.insert("ptr_done".into(), field(56, 8));
        layout.statuses.insert("ST_OK".into(), 0);
        layout.statuses.insert("ST_BAD_VER".into(), 2);

        let mut config = AiIslandConfig {
            cap_version: 3,
            clusters: 8,
            macs_per_cycle: 4096,
            acc_tile_m: 256,
            acc_tile_n: 256,
            acc_tile_k: 256,
            queues: 2,
            queue_depth: 64,
            cap_base: Some(0x100),
            desc_base: Some(0x0),
            block_mnk: Some(CapBlockMnk {
                m_low: 0,
                m_width: 4,
                n_low: 4,
                n_width: 4,
                k_low: 8,
                k_width: 4,
            }),
            ..AiIslandConfig::default()
        };
        config.cap_offsets.insert("version".into(), 0x00);
        config.cap_offsets.insert("clusters".into(), 0x04);
        config.cap_offsets.insert("macs_cycle".into(), 0x08);
        config.cap_offsets.insert("block_mnk".into(), 0x14);
        config.cap_offsets.insert("queues".into(), 0x18);
        config.cap_packed.words.insert(
            "queues".into(),
            vec![
                CapPackedField {
                    name: "queues".into(),
                    low: 0,
                    width: 16,
                },
                CapPackedField {
                    name: "queue_depth".into(),
                    low: 16,
                    width: 16,
                },
            ],
        );

        let mut m = TargetModel::new("ai");
        m.soc.ai_island = Some(AiIslandModel {
            instr_set: AiInstrSet {
                opcode_custom2: 0x5b,
                mask_f7f3op: 0xfe00_707f,
                match_enq: 0x0000_505b,
                match_poll: 0x0200_505b,
                match_qfence: 0x0400_505b,
                ..AiInstrSet::default()
            },
            config,
            desc_layout: layout,
        });
        m
    }

    #[test]
    fn emits_device_header_with_model_constants() {
        let m = island_model();
        let f = emit_island_h(&m, "0.1.0", "sha256:abc").unwrap();
        assert!(f.contents.contains("G6LC_AI_ISLAND_QUEUES 2"));
        assert!(f.contents.contains("G6LC_AI_ISLAND_QUEUE_DEPTH 64"));
        assert!(f.contents.contains("G6LC_AI_ISLAND_PTR_DONE_OFF 56"));
        assert!(f.contents.contains("G6LC_AI_ST_OK 0"));
        assert!(f.contents.contains("G6LC_AI_ST_BAD_VER 2"));
        assert!(f.contents.contains("G6LC_AI_DESC_VERSION 1"));
    }

    #[test]
    fn the_completion_macro_follows_the_ingested_layout() {
        let mut m = island_model();
        // Ticket at 63:16 and status at 15:0 — deliberately unlike the fallback, so a
        // passing assertion can only be reading `make_completion`.
        m.soc.ai_island.as_mut().unwrap().desc_layout.completion = Some(CompletionLayout {
            ticket_bit_low: 16,
            ticket_bit_high: 63,
            status_bit_low: 0,
            status_bit_high: 15,
        });
        let f = emit_island_h(&m, "0.1.0", "sha256:abc").unwrap();
        assert!(f.contents.contains("G6LC_AI_TICKET_SHIFT 16"));
        assert!(f.contents.contains("G6LC_AI_STATUS_SHIFT 0"));
        assert!(f
            .contents
            .contains("G6LC_AI_TICKET_MASK  0xffffffffffffULL"));
        assert!(f.contents.contains("G6LC_AI_STATUS_MASK  0xffffULL"));
    }

    #[test]
    fn the_completion_macro_uses_the_named_fallback_when_unpublished() {
        let m = island_model();
        let f = emit_island_h(&m, "0.1.0", "sha256:abc").unwrap();
        // No `make_completion` in the package: status above the ticket, per the IR's
        // single named fallback.
        assert!(f.contents.contains("G6LC_AI_TICKET_SHIFT 0"));
        assert!(f.contents.contains("G6LC_AI_STATUS_SHIFT 32"));
    }

    #[test]
    fn the_capability_window_is_a_table_from_the_model() {
        let m = island_model();
        let f = emit_island_c(&m, "0.1.0", "sha256:abc").unwrap();
        assert!(f.contents.contains("g6lc_ai_cap_words"));
        assert!(f.contents.contains("{ 0, 0x3ULL }"), "cap_version");
        assert!(f.contents.contains("{ 4, 0x8ULL }"), "clusters");
        assert!(f.contents.contains("{ 8, 0x1000ULL }"), "macs_per_cycle");
        assert!(f.contents.contains("{ 20, 0x888ULL }"), "packed block_mnk");
        assert!(f.contents.contains("{ 24, 0x400002ULL }"), "packed queues");
    }

    #[test]
    fn an_unresolved_capability_base_is_loud_and_undecoded() {
        let mut m = island_model();
        m.soc.ai_island.as_mut().unwrap().config.cap_base = None;
        let f = emit_island_c(&m, "0.1.0", "sha256:abc").unwrap();
        assert!(f.contents.contains("warn_report"));
        assert!(
            f.contents.contains("#include \"qemu/error-report.h\""),
            "warn_report needs its declaring header"
        );
        assert!(
            f.contents.contains("if (!s->cap_decoded"),
            "reads must be gated on a resolved base, not answered from a guess"
        );
    }

    #[test]
    fn an_empty_capability_window_emits_no_table_and_no_lookup() {
        let mut m = island_model();
        m.soc.ai_island.as_mut().unwrap().config.cap_offsets.clear();
        let f = emit_island_c(&m, "0.1.0", "sha256:abc").unwrap();
        assert!(
            !f.contents.contains("g6lc_ai_cap_words"),
            "a zero-length array is not valid C"
        );
        assert!(f.contents.contains("names no capability word"));
    }

    #[test]
    fn the_version_check_is_emitted_only_when_fully_resolved() {
        let m = island_model();
        let f = emit_island_c(&m, "0.1.0", "sha256:abc").unwrap();
        assert!(f.contents.contains("G6LC_AI_ST_BAD_VER"));

        let mut bare = island_model();
        bare.soc.ai_island.as_mut().unwrap().desc_layout.version = None;
        let f = emit_island_c(&bare, "0.1.0", "sha256:abc").unwrap();
        assert!(
            !f.contents.contains("G6LC_AI_DESC_VERSION"),
            "no published version means no check, not a check against a guess"
        );
    }

    #[test]
    fn a_full_ring_is_distinguishable_from_a_pending_poll() {
        let m = island_model();
        let f = emit_island_c(&m, "0.1.0", "sha256:abc").unwrap();
        assert!(f
            .contents
            .contains("Ring full. Zero, not the pending sentinel"));
        assert!(f.contents.contains("return G6LC_AI_POLL_PENDING;"));
    }

    #[test]
    fn skips_emission_without_a_resolved_island() {
        let m = TargetModel::default();
        assert!(emit_island_h(&m, "0.1.0", "sha256:abc").is_none());
        assert!(emit_island_c(&m, "0.1.0", "sha256:abc").is_none());
    }

    #[test]
    fn skips_emission_when_the_descriptor_geometry_is_unresolved() {
        let mut m = island_model();
        m.soc.ai_island.as_mut().unwrap().desc_layout.fields.clear();
        assert!(
            emit_island_h(&m, "0.1.0", "sha256:abc").is_none(),
            "no ptr_done offset means the device cannot be emitted"
        );
        let mut m = island_model();
        m.soc.ai_island.as_mut().unwrap().desc_layout.desc_bytes = 0;
        assert!(emit_island_c(&m, "0.1.0", "sha256:abc").is_none());
    }
}
