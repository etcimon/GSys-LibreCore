#!/usr/bin/env python3
# hyp8: insert `// svt-stage:` region/class/use pragmas into the staged
# hyp8 modules. Comment-only inserts; design intent unchanged.
# Anchors are verified (exact substring, expected count) before writing.
import io, os, sys

# hyp8: tree root passed on argv[1] or HYP_CORE_DIR (kept out of the file
# so no host-path identity token is embedded).
ROOT = sys.argv[1] if len(sys.argv) > 1 else os.environ["HYP_CORE_DIR"]

# (path, ops) — op = ("before", anchor, text) insert text on its own line
# before the first line containing anchor; ("after", anchor, text) after.
# ("body", stage, extra) — begin right after the port-list `);`, end before
# endmodule. ("classes", {name: cls}) appended before endmodule.
# ("use", stage, nets) emits `// svt-stage: use <stage> on=<nets>` before
# endmodule.

def B(anchor, text):  return ("before", anchor, text)
def A(anchor, text):  return ("after",  anchor, text)

EDITS = {
 "core/stb_fwd.sv": [
   B("  // ---------------- F1: candidate match (registered) ----------------",
     "  // svt-stage: begin F1"),
   B("  // ---------------- F2: per-byte winner select (registered) ----------------",
     "  // svt-stage: end F1\n  // svt-stage: begin F2"),
   B("  // ---------------- F3: winner data gather + response ----------------",
     "  // svt-stage: end F2\n  // svt-stage: begin F3"),
   B("endmodule",
     "  // svt-stage: end F3\n"
     "  // svt-stage: class F1 value\n"
     "  // svt-stage: class F2 value\n"
     "  // svt-stage: class F3 value"),
 ],
 "core/multiplier.sv": [
   B("    // ---- S1: tile products + correction row ----",
     "    // svt-stage: begin S1"),
   B("    // ---- S2-S5: four carry-save stages, LPS compressor levels each ----",
     "    // svt-stage: end S1\n    // svt-stage: begin S2_5"),
   B("    // ---- S6: first CPA half (low HW bits + carry) ----",
     "    // svt-stage: end S2_5\n    // svt-stage: begin S6"),
   B("    // ---- S7: second CPA half -> full product mod 2**RW ----",
     "    // svt-stage: end S6\n    // svt-stage: begin S7"),
   B("    // ---- S8: result/flags -> output register ----",
     "    // svt-stage: end S7\n    // svt-stage: begin S8"),
   B("  end else if (MSTAGES > 1) begin : gen_legacy_pipe",
     "    // svt-stage: end S8"),
   B("endmodule",
     "  // svt-stage: class S1 value\n"
     "  // svt-stage: class S2_5 value\n"
     "  // svt-stage: class S6 value\n"
     "  // svt-stage: class S7 value\n"
     "  // svt-stage: class S8 value"),
 ],
 "core/alu.sv": [
   B("    // A1: operand conditioning + low-half work, registered.",
     "    // svt-stage: begin A1"),
   B("    // hyp8: A1 low-half forward -- the low 32 bits of the add/logic",
     "    // svt-stage: end A1\n    // svt-stage: begin A2"),
   B("  end else begin : gen_comb",
     "    // svt-stage: end A2"),
   B("endmodule",
     "  // svt-stage: class A1 value\n"
     "  // svt-stage: class A2 value"),
 ],
 "core/branch_unit.sv": [
   B("  // B1: capture + low-half target add (registered).",
     "  // svt-stage: begin B1"),
   B("  // B2: high-half add + compare/mispredict resolution + exception.",
     "  // svt-stage: end B1\n  // svt-stage: begin B2"),
   B("endmodule",
     "  // svt-stage: end B2\n"
     "  // svt-stage: class B1 value\n"
     "  // svt-stage: class B2 value"),
 ],
 "core/frontend/g6lc_bp_tage.sv": [
   B("  // ----- Base bimodal table (PC index) -----",
     "  // svt-stage: begin P1"),
   B("  // hyp8 P2: comb off the P1 registers; the verdict registers follow.",
     "  // svt-stage: end P1\n  // svt-stage: begin P2 window=1"),
   B("  for (genvar i = 0; i < G6LCCfg.INSTR_PER_FETCH; i++) begin : gen_out",
     "  // svt-stage: end P2"),
   B("endmodule",
     "  // svt-stage: class P1 value\n"
     "  // svt-stage: class P2 value"),
 ],
 "core/cache_subsystem/wt_dcache_wbuffer.sv": [
   B("  // hyp8: W1/W2 request pipeline (HypCfg.WbufPipelined). During W1 the",
     "  // svt-stage: begin W1"),
   B("  // hyp8: the conflict verdict applies to the effective (W2) request —",
     "  // svt-stage: end W1\n  // svt-stage: begin W2"),
   B("endmodule",
     "  // svt-stage: end W2\n"
     "  // svt-stage: class W1 value\n"
     "  // svt-stage: class W2 value"),
 ],
 "core/load_unit.sv": [
   B("  // hyp8 L3/L4/L5: response-wait, align and publish staging.",
     "  // svt-stage: begin L3"),
   B("  endgenerate",
     "  // svt-stage: end L3"),
   B("  // hyp8 L5 publish. data_rvalid only captures into the slot (rpend_q);",
     "  // svt-stage: begin L5"),
   B("  // hyp8 L2: staged forward request — fired when the D$ request commits",
     "  // svt-stage: end L5\n  // svt-stage: begin L2"),
   B("  // hyp8 H5: fire once when a granted slot's response has not arrived by",
     "  // svt-stage: end L2"),
   B("  // hyp8 L4/L5: the publishing slot's captured response is merged with",
     "  // svt-stage: begin L4"),
   B("endmodule",
     "  // svt-stage: end L4\n"
     "  // svt-stage: class L2 value\n"
     "  // svt-stage: class L3 value\n"
     "  // svt-stage: class L4 value\n"
     "  // svt-stage: class L5 value"),
 ],
 "core/g6lc_mmu/g6lc_tlb.sv": [
   B("  // hyp8 (M1, TlbStages=3): T1 captures the lookup request (vaddr, ASID,",
     "  // svt-stage: begin T1"),
   B("  // hyp8: this comb only computes the per-entry match vectors now; the",
     "  // svt-stage: end T1\n  // svt-stage: begin T2"),
   B("  assign asid_to_be_flushed_is0",
     "  // svt-stage: end T2"),
   B("endmodule",
     "  // svt-stage: class T1 value\n"
     "  // svt-stage: class T2 value"),
 ],
 "core/id_stage.sv": [
   B("    // per-lane staged datapath: s1 (context pack) -> d1_q -> s2 -> d2_q -> s3",
     "    // svt-stage: begin D1"),
   B("      // D2: instruction-bit decode of the D1 register",
     "    // svt-stage: end D1\n    // svt-stage: begin D2"),
   B("      g6lc_decode_s3 #(",
     "    // svt-stage: end D2\n    // svt-stage: begin D3"),
   A("    assign dec_macro_ack = dec_adv && d1_vq[0];",
     "    // svt-stage: end D3"),
   B("endmodule",
     "  // svt-stage: use D1 on=d1_q,d1_vq\n"
     "  // svt-stage: use D2 on=d2_q,d2_vq\n"
     "  // svt-stage: class D1 value\n"
     "  // svt-stage: class D2 value\n"
     "  // svt-stage: class D3 value"),
 ],
 "core/ooo/g6lc_iq_bank.sv": [
   B("  // Candidate eligibility: live, not taken, not cancelled, rdy bits set",
     "  // svt-stage: begin SEL"),
   B("endmodule",
     "  // svt-stage: end SEL\n"
     "  // svt-stage: class SEL decision"),
 ],
 "core/ooo/g6lc_iq_arb.sv": [
   B("  always_comb begin : res_next",
     "  // svt-stage: begin ARB"),
   B("endmodule",
     "  // svt-stage: end ARB\n"
     "  // svt-stage: class ARB decision"),
 ],
 "core/ooo/g6lc_ooo_dispatch.sv": [
   B("  // hyp8: issue staging. Each presented candidate enters iss_q for exactly",
     "  // svt-stage: begin ISS"),
   B("  g6lc_lsq #(",
     "  // svt-stage: end ISS"),
   B("endmodule",
     "  // svt-stage: class ISS decision"),
 ],
 "core/frontend/g6lc_fe_nextline.sv": [
   B("  // Untagged line table + read-ahead",
     "  // svt-stage: begin NL"),
   B("endmodule",
     "  // svt-stage: end NL\n"
     "  // svt-stage: class NL decision"),
 ],
 # whole-body stage modules: begin after port-list `);`, end before endmodule
 "core/ooo/g6lc_lsq_cam_bank.sv": [("body", "C",   ""), ("cls", "C",  "value")],
 "core/ooo/g6lc_lsq_event.sv":       [("body", "E",   ""), ("cls", "E",  "value")],
 "core/ooo/g6lc_lsq_reduce.sv":      [("body", "R",   ""), ("cls", "R",  "value")],
 "core/ooo/g6lc_lsq_verdict.sv":     [("body", "V",   " window=3"), ("cls", "V", "value")],
 "core/csr_decode.sv":           [("body", "C1",  ""), ("cls", "C1", "value")],
 "core/csr_read.sv":             [("body", "C2",  ""), ("cls", "C2", "value")],
 "core/csr_write.sv":            [("body", "C3",  ""), ("cls", "C3", "value")],
 "core/ooo/g6lc_rename_resolve.sv":[("body","RR",  ""), ("cls", "RR", "decision")],
 "core/sb_commit_bundle.sv":     [("body", "CB",  ""), ("cls", "CB", "decision")],
 "core/scoreboard.sv":           [("body", "RDY", ""), ("cls", "RDY","decision")],
}

def run():
    for rel, ops in EDITS.items():
        p = os.path.join(ROOT, rel)
        with io.open(p, "r", encoding="utf-8", newline="\n") as f:
            lines = f.read().split("\n")
        for op in ops:
            kind = op[0]
            if kind in ("before", "after"):
                _, anchor, text = op
                hits = [i for i, l in enumerate(lines) if anchor in l]
                if len(hits) != 1:
                    print(f"  !! {rel}: anchor count {len(hits)} for {anchor[:60]!r} — SKIPPED")
                    continue
                ins = hits[0] + (1 if kind == "after" else 0)
                lines[ins:ins] = text.split("\n")
                print(f"  ok {rel}: {kind} {anchor[:50]!r}")
            elif kind == "body":
                _, stage, extra = op
                # first `);` line after the `module` keyword
                mi = next(i for i, l in enumerate(lines) if l.startswith("module "))
                pi = next(i for i in range(mi, len(lines)) if lines[i].strip() == ");")
                lines.insert(pi + 1, f"  // svt-stage: begin {stage}{extra}")
                ei = next(i for i in range(len(lines) - 1, mi, -1)
                          if lines[i].startswith("endmodule"))
                lines.insert(ei, f"  // svt-stage: end {stage}")
                print(f"  ok {rel}: body stage {stage}")
            elif kind == "cls":
                _, stage, cls = op
                ei = next(i for i in range(len(lines) - 1, 0, -1)
                          if lines[i].startswith("endmodule"))
                lines.insert(ei, f"  // svt-stage: class {stage} {cls}")
        with io.open(p, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(lines))
        print(f"done {rel}")

if __name__ == "__main__":
    run()
