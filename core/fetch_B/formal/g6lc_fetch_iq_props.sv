// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Bounded formal: I6 as a NON-INTERFERENCE property against the live IQ
// (`core/fetch_B/instr_queue.sv`).
//
// I6 (firmware-boot-principles.md sB): "IQ order is program order. Head
// selection must not depend on opcode, `rd`, or FU." The second sentence is not
// a single-trace property -- no one execution can witness "does not depend on".
// It is an information-flow claim, so it is proven by SELF-COMPOSITION: two
// copies of the queue are driven with identical control and *different*
// instruction payloads, and every control output must agree.
//
//   identical : flush, hart, addr_i, valid_i, leftover_complete_i, exception_*,
//               predict_address_i, cf_type_i, fetch_entry_ready_i
//   different : instr_i          (the raw instruction bits -- opcode, rd, funct)
//   asserted  : ready_o, consumed_o, replay_o, replay_addr_o,
//               fetch_entry_valid_o, and each emitted .address / .hart_id
//
// `cf_type_i` is deliberately held identical, because control flow IS legitimate
// input to head selection (`packet_upto_cf` ends a packet at a taken CF, and
// `instr_scan` predecodes it). What I6 forbids is the *raw encoding* reaching the
// selection. `.instruction` is of course allowed to differ -- it is the payload,
// and asserting it equal would be asserting the opposite of the point.
//
// Why this is worth a proof: SPEC.md s4 records that BTB-miss `jalr` is NoCF and
// must not end a packet ("NEGATIVE always-JumpR"), i.e. there has already been a
// pull towards deciding order from the encoding. A non-interference proof makes
// that class of change fail immediately instead of at a soak.
//
// Run: sby -f core/fetch_B/formal/g6lc_fetch_iq.sby
//      cva6-build verify --formal

module g6lc_fetch_iq_props #(
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

  // --- shared (identical) stimulus -----------------------------------------
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

  // --- the only difference: the raw instruction payload --------------------
  logic [SLOTS-1:0][31:0] instr_a, instr_b;

  logic rst_init_q = 1'b1;
  logic rst_ni;
  always_ff @(posedge clk_i) rst_init_q <= 1'b0;
  assign rst_ni = ~rst_init_q;

  logic          ready_a, ready_b, replay_a, replay_b;
  logic [SLOTS-1:0] consumed_a, consumed_b;
  logic [VLEN-1:0]  replay_addr_a, replay_addr_b;
  fe_t  [NI-1:0]    entry_a, entry_b;
  logic [NI-1:0]    entry_v_a, entry_v_b;

  instr_queue #(.CVA6Cfg(Cfg), .fetch_entry_t(fe_t)) qa (
      .clk_i, .rst_ni, .flush_i, .hart_i,
      .instr_i(instr_a), .addr_i, .valid_i, .leftover_complete_i,
      .ready_o(ready_a), .consumed_o(consumed_a),
      .exception_i, .exception_addr_i, .exception_gpaddr_i,
      .exception_tinst_i, .exception_gva_i, .predict_address_i, .cf_type_i,
      .replay_o(replay_a), .replay_addr_o(replay_addr_a),
      .fetch_entry_o(entry_a), .fetch_entry_valid_o(entry_v_a),
      .fetch_entry_ready_i
  );

  instr_queue #(.CVA6Cfg(Cfg), .fetch_entry_t(fe_t)) qb (
      .clk_i, .rst_ni, .flush_i, .hart_i,
      .instr_i(instr_b), .addr_i, .valid_i, .leftover_complete_i,
      .ready_o(ready_b), .consumed_o(consumed_b),
      .exception_i, .exception_addr_i, .exception_gpaddr_i,
      .exception_tinst_i, .exception_gva_i, .predict_address_i, .cf_type_i,
      .replay_o(replay_b), .replay_addr_o(replay_addr_b),
      .fetch_entry_o(entry_b), .fetch_entry_valid_o(entry_v_b),
      .fetch_entry_ready_i
  );

  always_ff @(posedge clk_i) begin
    if (rst_ni && NH > 1) assume (hart_i < HARTW'(NH));
  end

  // --- I6: control flow is identical under a different encoding ------------
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      // Back-pressure and packet consumption cannot read the encoding.
      assert (ready_a == ready_b);
      assert (consumed_a == consumed_b);
      // Replay decisions likewise.
      assert (replay_a == replay_b);
      if (replay_a) assert (replay_addr_a == replay_addr_b);
      // Head selection: the same slots issue, in the same order.
      assert (entry_v_a == entry_v_b);
      for (int unsigned i = 0; i < NI; i++) begin
        if (entry_v_a[i]) begin
          assert (entry_a[i].address == entry_b[i].address);
          assert (entry_a[i].hart_id == entry_b[i].hart_id);
        end
      end
    end
  end

  // --- reachability: the payloads really do differ -------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      cover (instr_a != instr_b && entry_v_a[0]);
      cover (|entry_v_a);
      cover (replay_a);
    end
  end
`endif

endmodule
