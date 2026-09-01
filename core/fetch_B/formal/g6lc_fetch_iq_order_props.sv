// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Bounded formal: I6 clause 1 (program-order issue) against the live IQ
// (`core/fetch_B/instr_queue.sv`).
//
// I6 (firmware-boot-principles.md sB): "IQ order is program order. Head
// selection must not depend on opcode, `rd`, or FU." The existing
// `g6lc_fetch_iq.sby` proves clause 2 (non-interference / value independence)
// by self-composition. This contract proves clause 1: the live queue issues
// instructions in the order of the per-entry `push_seq` program-order counter.
//
// The geometry is the same reduced-but-faithful envelope used by
// `g6lc_fetch_iq.sby`: FETCH_WIDTH=64, RVC, 2 harts, 2 issue ports. XLEN/VLEN
// are reduced to 32 to keep the bit-level cone small; the order logic is
// independent of address/exception width, so this is equivalent for the
// property being checked.
//
// Run: sby -f core/fetch_B/formal/g6lc_fetch_iq_order.sby
//      cva6-build verify --formal

module g6lc_fetch_iq_order_props #(
    parameter int unsigned FW = 64,  // FETCH_WIDTH bits
    parameter int unsigned AB = 3,   // FETCH_ALIGN_BITS
    parameter int unsigned NH = 2,   // NrHarts
    parameter int unsigned NI = 2    // NrIssuePorts
) (
    input logic clk_i
);

`ifdef FORMAL
  import ariane_pkg::*;

  localparam int unsigned VLEN  = 32;
  localparam int unsigned XLEN  = 32;
  localparam int unsigned GPLEN = 32;
  localparam int unsigned SLOTS = FW / 16;
  localparam int unsigned HARTW = (NH > 1) ? $clog2(NH) : 1;

  function automatic config_pkg::cva6_cfg_t mk_cfg();
    config_pkg::cva6_cfg_t c;
    c                      = config_pkg::cva6_cfg_empty;
    c.XLEN                 = XLEN;
    c.VLEN                 = VLEN;
    c.GPLEN                = GPLEN;
    c.FETCH_WIDTH          = FW;
    c.FETCH_ALIGN_BITS     = AB;
    c.INSTR_PER_FETCH      = SLOTS;
    c.LOG2_INSTR_PER_FETCH = $clog2(SLOTS);
    c.RVC                  = 1'b1;
    c.NrHarts              = NH;
    c.NrIssuePorts         = NI;
    c.FtqDepth             = 0;  // smt2 ships FtqDepth=0
    return c;
  endfunction

  localparam config_pkg::cva6_cfg_t Cfg = mk_cfg();

  // Layout-identical to the localparam types in `core/cva6.sv`; the queue only
  // stores and forwards these, so a structural copy is faithful here.
  typedef struct packed {
    cf_t             cf;
    logic [VLEN-1:0] predict_address;
  } bp_sbe_t;

  typedef struct packed {
    logic [XLEN-1:0]  cause;
    logic [XLEN-1:0]  tval;
    logic [GPLEN-1:0] tval2;
    logic [31:0]      tinst;
    logic             gva;
    logic             valid;
  } exc_t;

  typedef struct packed {
    logic [VLEN-1:0]  address;
    logic [31:0]      instruction;
    bp_sbe_t          branch_predict;
    exc_t             ex;
    logic [HARTW-1:0] hart_id;
  } fe_t;

  // --- stimulus -------------------------------------------------------------
  logic                        flush_i, leftover_complete_i, exception_gva_i;
  logic [HARTW-1:0]            hart_i;
  logic [SLOTS-1:0][VLEN-1:0]  addr_i;
  logic [SLOTS-1:0]            valid_i;
  frontend_exception_t         exception_i;
  logic [VLEN-1:0]             exception_addr_i, predict_address_i;
  logic [GPLEN-1:0]            exception_gpaddr_i;
  logic [31:0]                 exception_tinst_i;
  cf_t  [SLOTS-1:0]            cf_type_i;
  logic [NI-1:0]               fetch_entry_ready_i;
  logic [SLOTS-1:0][31:0]      instr_i;

  // --- observed outputs -----------------------------------------------------
  logic          ready_o, replay_o;
  logic [SLOTS-1:0] consumed_o;
  logic [VLEN-1:0]  replay_addr_o;
  fe_t  [NI-1:0]    fetch_entry_o;
  logic [NI-1:0]    fetch_entry_valid_o;

  logic rst_init_q = 1'b1;
  logic rst_ni;
  always_ff @(posedge clk_i) rst_init_q <= 1'b0;
  assign rst_ni = ~rst_init_q;

  instr_queue #(.CVA6Cfg(Cfg), .fetch_entry_t(fe_t)) dut (
      .clk_i, .rst_ni, .flush_i, .hart_i,
      .instr_i, .addr_i, .valid_i, .leftover_complete_i,
      .ready_o, .consumed_o,
      .exception_i, .exception_addr_i, .exception_gpaddr_i,
      .exception_tinst_i, .exception_gva_i, .predict_address_i, .cf_type_i,
      .replay_o, .replay_addr_o,
      .fetch_entry_o, .fetch_entry_valid_o, .fetch_entry_ready_i
  );

  // --- environment: the realigner always presents valid slots in PC order.
  // Tie this off as an assumption rather than an obligation of the queue.
  logic env_valid_prefix_ok, env_addr_order_ok, env_cf_valid;

  always_comb begin
    env_valid_prefix_ok = 1'b1;
    for (int unsigned i = 1; i < SLOTS; i++) begin
      if (valid_i[i]) env_valid_prefix_ok &= valid_i[i-1];
    end
    env_addr_order_ok = 1'b1;
    for (int unsigned i = 0; i < SLOTS; i++) begin
      for (int unsigned j = 0; j < SLOTS; j++) begin
        if (i < j && valid_i[i] && valid_i[j]) env_addr_order_ok &= (addr_i[i] < addr_i[j]);
      end
    end
    env_cf_valid = 1'b1;
    for (int unsigned i = 0; i < SLOTS; i++) begin
      if (valid_i[i]) begin
        env_cf_valid &= ((cf_type_i[i] == NoCF)   || (cf_type_i[i] == Branch) ||
                         (cf_type_i[i] == Jump)   || (cf_type_i[i] == JumpR)  ||
                         (cf_type_i[i] == Return));
      end
    end
  end

  // Environment assumes live in the always_ff block below (same encoding as
  // the asserts, so abc-bmc3 cannot discharge them on an unclocked frame).

  // --- helper: push_seq of the last port that actually fires this cycle -----
  logic [15:0] issued_pseq;
  logic        issued_fire;

  always_comb begin
    issued_pseq = 16'd0;
    issued_fire = 1'b0;
    for (int unsigned p = 0; p < NI; p++) begin
      if (dut.fire_prefix[p]) begin
        for (int unsigned f = 0; f < SLOTS; f++) begin
          if (dut.idx_ds[p][f]) begin
            issued_pseq = dut.instr_data_out[f].push_seq;
            issued_fire = 1'b1;
          end
        end
      end
    end
  end

  // --- temporal: issued push_seqs are non-decreasing over time --------------
  logic [15:0] last_pseq_q;
  logic        last_valid_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      last_pseq_q  <= 16'd0;
      last_valid_q <= 1'b0;
    end else if (flush_i) begin
      // A flush resets the queue's program-order counter; drop the last marker
      // so the first post-flush issue is not compared against pre-flush state.
      last_pseq_q  <= 16'd0;
      last_valid_q <= 1'b0;
    end else if (issued_fire) begin
      last_pseq_q  <= issued_pseq;
      last_valid_q <= 1'b1;
    end
  end

  // --- I6 clause 1: helper signals for concurrent assertions ----------------
  // Convert the quantified properties into a single boolean each so that
  // `assert property` can be used at module scope (read_slang supports this
  // shape, while implication sequences inside `generate` are not).
  logic pseq_monotone, head_select_ordered, multi_port_ordered, issued_addr_ok;

  always_comb begin
    pseq_monotone = 1'b1;
    if (last_valid_q && issued_fire) pseq_monotone = (issued_pseq >= last_pseq_q);

    head_select_ordered = 1'b1;
    for (int unsigned f0 = 0; f0 < SLOTS; f0++) begin
      for (int unsigned f1 = 0; f1 < SLOTS; f1++) begin
        if (f0 != f1 && !dut.instr_queue_empty[f0] && !dut.instr_queue_empty[f1] &&
            dut.idx_ds[0][f0]) begin
          head_select_ordered &= (dut.instr_data_out[f0].push_seq <= dut.instr_data_out[f1].push_seq);
        end
      end
    end

    multi_port_ordered = 1'b1;
    for (int unsigned p = 0; p < NI; p++) begin
      for (int unsigned q = 0; q < NI; q++) begin
        if (p < q && dut.fire_prefix[q]) begin
          for (int unsigned fp = 0; fp < SLOTS; fp++) begin
            for (int unsigned fq = 0; fq < SLOTS; fq++) begin
              if (dut.idx_ds[p][fp] && dut.idx_ds[q][fq]) begin
                multi_port_ordered &= (dut.instr_data_out[fp].push_seq <= dut.instr_data_out[fq].push_seq);
              end
            end
          end
        end
      end
    end

    issued_addr_ok = 1'b1;
    for (int unsigned p = 0; p < NI; p++) begin
      for (int unsigned f = 0; f < SLOTS; f++) begin
        if (dut.fire_prefix[p] && dut.idx_ds[p][f]) begin
          issued_addr_ok &= (dut.fetch_entry_o[p].address == dut.instr_data_out[f].pc);
        end
      end
    end
  end

  // FIFO data-order is proved on the live `cva6_fifo_v3` in
  // `cva6_fifo_v3_order.sby` (insertion order + control self-composition).
  // That makes `pseq_monotone` a corollary of "each head is the oldest
  // unmatched push in that slot FIFO" plus greedy age-select — not an
  // assumption about unreachable `mem_q`. Do not re-introduce a
  // `push_seq_range_ok` assume; it made the monotone claim vacuous.
  //
  // Immediate asserts inside always_ff, not concurrent SVA: abc-bmc3's AIGER
  // path treats clk_i as $anyseq and checks sampled properties on unclocked
  // frames (the historical FAIL at step 4 with PI_clk_i held 0).

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assume (env_valid_prefix_ok);
      assume (env_addr_order_ok);
      assume (env_cf_valid);
      assert (pseq_monotone);
      assert (head_select_ordered);
      assert (multi_port_ordered);
      assert (issued_addr_ok);
      cover (dut.fire_prefix[0]);
      cover (dut.fire_prefix[1]);
      cover (dut.replay_o);
      cover (dut.instr_queue_empty == '0 && dut.idx_ds[0][0]);
      cover (last_valid_q && issued_fire);
    end
  end
`endif

endmodule
