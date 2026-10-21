// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U5 production full OoO package — sizing helpers and phase status.

package g6lc_ooo_pkg;

  // Phase status (documentation for agents; not synthesised).
  // U5.0 recovery hardening  — scoreboard younger-than-branch cancel (done)
  // U5.1 rename/PRF/RAT      — multi-port rename + PRF write-through + IRO cutover
  // U5.2 ROB                 — multi-WB complete-by-tid; dual free
  // U5.3 IQ/wakeup/select    — chain wakeup + dual age-ordered grant
  // U5.4 OoO LSQ + memdep    — live AGU + CAM/STL + store-set
  // U5.5 widen / formal      — remaining

  function automatic int unsigned ooo_prf_w(input int unsigned prf_entries);
    return (prf_entries <= 2) ? 1 : $clog2(prf_entries);
  endfunction

  function automatic int unsigned ooo_rob_w(input int unsigned rob_entries);
    return (rob_entries <= 2) ? 1 : $clog2(rob_entries);
  endfunction

  // Program-order key: circular trans_id distance from the oldest live slot.
  // Sound only while both operands are scoreboard-live; width is the config's
  // TRANS_ID_BITS so the modular subtraction wraps exactly like the scoreboard.
  function automatic logic ooo_age_older(input int unsigned width, input logic [31:0] a,
                                         input logic [31:0] b, input logic [31:0] cp);
    logic [31:0] mask, am, bm, cm;
    mask = (32'd1 << width) - 32'd1;
    am = a & mask;
    bm = b & mask;
    cm = cp & mask;
    // The circular order is [cp, 2^width), then [0, cp).
    // Compare within a half in parallel with deciding which half each
    // operand occupies. This removes two subtractors from the age gates
    // shared by IQ, LSQ, ROB and store-buffer consumers.
    // Mask first: callers may carry unrelated upper bits; width=0 still
    // compares two zero distances, and width>=32 retains the old mask.
    return ((am < cm) == (bm < cm)) ? (am < bm) : (bm < cm);
  endfunction

  function automatic logic [31:0] ooo_age_dist(input int unsigned width, input logic [31:0] a,
                                               input logic [31:0] cp);
    logic [31:0] mask;
    mask = (32'd1 << width) - 32'd1;
    return (a - cp) & mask;
  endfunction

  // Keep in lockstep with store_buffer.sv's DEPTH_SPEC: an LSQ store credit
  // reserves a speculative-queue slot, so g6lc_ooo_dispatch refuses a
  // configuration whose store queue outnumbers the slots it reserves. The
  // non-DeepSpec fallback is g6lc_core_pkg::DEPTH_SPEC (=4), inlined as a literal
  // so this package does not import g6lc_core_pkg.
  function automatic int unsigned ooo_spec_store_depth(input config_pkg::g6lc_cfg_t cfg);
    int unsigned clamped;
    if (!cfg.DeepSpecEn) return 4;
    clamped = (cfg.MaxOutstandingStores < 4) ? 4 :
              (cfg.MaxOutstandingStores > 16) ? 16 : cfg.MaxOutstandingStores;
    if (clamped <= 4) return 4;
    if (clamped <= 8) return 8;
    return 16;
  endfunction

  // hyp8 (group 4/5): producer latency class of a (fu, op) pair, used by the
  // banked issue queue's speculative-wakeup countdown (analysis/g6lc_iq.md,
  // analysis/execute.md). A countdown of hyp_lat_cycles(class)-1 is broadcast
  // when the producer is selected, so the consumer's rdy lands when the
  // producer's result does. Anything not provably fixed-latency is
  // LAT_NONSPEC (conservative: consumers wait for the real WB).
  function automatic g6lc_hyp_pkg::hyp_lat_class_e ooo_lat_class(
      input g6lc_core_pkg::fu_t fu, input g6lc_core_pkg::fu_op op);
    unique case (fu)
      g6lc_core_pkg::ALU: begin
        unique case (op)
          // single-cycle add/logic result on the low 32 bits (AluStaggered
          // stage 1); every other op needs the full ALU latency.
          g6lc_core_pkg::ADD,      g6lc_core_pkg::SUB,
          g6lc_core_pkg::ADDW,     g6lc_core_pkg::SUBW,
          g6lc_core_pkg::XORL,     g6lc_core_pkg::ORL,
          g6lc_core_pkg::ANDL,     g6lc_core_pkg::ANDN,
          g6lc_core_pkg::ORN,      g6lc_core_pkg::XNOR,
          g6lc_core_pkg::SH1ADD,   g6lc_core_pkg::SH2ADD,
          g6lc_core_pkg::SH3ADD,   g6lc_core_pkg::SH1ADDUW,
          g6lc_core_pkg::SH2ADDUW, g6lc_core_pkg::SH3ADDUW,
          g6lc_core_pkg::ADDUW:
            ooo_lat_class = g6lc_hyp_pkg::LAT_ALU_LOW;
          default:
            ooo_lat_class = g6lc_hyp_pkg::LAT_ALU_FULL;
        endcase
      end
      g6lc_core_pkg::CTRL_FLOW: ooo_lat_class = g6lc_hyp_pkg::LAT_ALU_FULL;
      g6lc_core_pkg::MULT: begin
        unique case (op)
          // fixed-latency multiplies (incl. carry-less mult through the same
          // pipe); division/remainder iterate in serdiv -> LAT_NONSPEC.
          g6lc_core_pkg::MUL,    g6lc_core_pkg::MULH,   g6lc_core_pkg::MULHU,
          g6lc_core_pkg::MULHSU, g6lc_core_pkg::MULW,
          g6lc_core_pkg::CLMUL,  g6lc_core_pkg::CLMULH, g6lc_core_pkg::CLMULR:
            ooo_lat_class = g6lc_hyp_pkg::LAT_MUL;
          default:
            ooo_lat_class = g6lc_hyp_pkg::LAT_NONSPEC;
        endcase
      end
      g6lc_core_pkg::LOAD: ooo_lat_class = g6lc_hyp_pkg::LAT_LOAD;
      g6lc_core_pkg::FPU: begin
        unique case (op)
          // fixed-latency fpnew pipe ops; FDIV/FSQRT iterate.
          g6lc_core_pkg::FADD,     g6lc_core_pkg::FSUB,
          g6lc_core_pkg::FMUL,     g6lc_core_pkg::FMIN_MAX,
          g6lc_core_pkg::FMADD,    g6lc_core_pkg::FMSUB,
          g6lc_core_pkg::FNMSUB,   g6lc_core_pkg::FNMADD,
          g6lc_core_pkg::FCVT_F2I, g6lc_core_pkg::FCVT_I2F,
          g6lc_core_pkg::FCVT_F2F, g6lc_core_pkg::FMV_X2F,
          g6lc_core_pkg::FMV_F2X,  g6lc_core_pkg::FSGNJ,
          g6lc_core_pkg::FCMP,     g6lc_core_pkg::FCLASS:
            ooo_lat_class = g6lc_hyp_pkg::LAT_FP_FIXED;
          default:
            ooo_lat_class = g6lc_hyp_pkg::LAT_NONSPEC;
        endcase
      end
      g6lc_core_pkg::FPU_VEC: ooo_lat_class = g6lc_hyp_pkg::LAT_FP_FIXED;
      // STORE / CSR / CVXIF / ACCEL / AES / NONE: never the tagged source of
      // a speculative wakeup.
      default: ooo_lat_class = g6lc_hyp_pkg::LAT_NONSPEC;
    endcase
  endfunction

  // Replay broadcast record (kill-by-tid re-arm, analysis/g6lc_iq.md): the
  // LSU-side producer lands later (dispatch ties it low for now); the iq
  // ports carry the two fields directly.
  typedef struct packed {
    logic        valid;
    logic [31:0] tid;
  } ooo_replay_t;

  // hyp8 (group 4/5): staged-rename lane record. The R1/R2/R3 pipeline
  // (g6lc_rename_read/resolve/publish) moves one of these per dispatch lane
  // per group. Physical tags are stored 8 bits wide -- dispatch's
  // elaboration guard already refuses PRF_W/FPRF_W > 8 -- and hart ids fit
  // two bits for every supported NrHarts (<= 4).
  typedef struct packed {
    logic        v;
    logic [1:0]  hart;
    logic [4:0]  rs1, rs2, rs3, rd;
    logic        need_rd, is_branch;
    logic        f_rd, f_rs1, f_rs2, f_rs3;   // register class per operand
    // R1 map reads (raw); R2 resolves them against the bypass records.
    logic [7:0]  prs1, prs2, old;
    logic [7:0]  fprs1, fprs2, fprs3, fold;
    logic        rs1_rdy, rs2_rdy, rs3_rdy;
    // R1 reservations: picked destinations + the checkpoint slot.
    logic        do_alloc, do_falloc;
    logic [7:0]  prd, fprd;
    logic        do_ckpt;
    logic [5:0]  ckpt_slot;
  } ooo_ren_lane_t;

endpackage
